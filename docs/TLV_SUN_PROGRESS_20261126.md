# 太阳 TLV 候选：本轮实现与验证

2026-11-26。范围仅为独立原地图工程 `F:/逸剑godot`。旧孤岛工程与保留的组合样场景未由本轮候选替换。默认入口仍为 `project/worlds.tscn`；当前 TLV 引用只在 `project/source_tlv_candidate/` 与显式验证脚本中，没有默认运行集成。

已打通的候选链路为：独立正交 `sun_probe` 在真实场景投影图中查询太阳阴影，同时求源 LightFunction → 近/远两级 64³ 源坐标体积 → RGBA16F SH 注入和源八点滤波 → 六类透明材质的太阳接收。Ocean 使用 L0；Water、Waterfall、Smoke1、SmokeSubUV、Splash 使用对应方向解码。现有局部直射、天空 SH9、材质表面与透明合成保持各自路径。这里的“真实阴影”指 Godot 实际 caster/atlas，不是已取得原 UE 的原生阴影图或逐像素相等结果。

## 证据与失败记录

| 运行 | 当前结果 | 确切证明或问题 |
|---|---|---|
| `probe-v1` | 通过 | 不透明、裁切遮罩、形变遮罩、关阴影、无灯五组控制；每组 262,144 查询点与解析结果相等；无引擎错误/警告。 |
| `scene-v1` | 通过 | 无名岛/游仙村共10次近远级捕获，全部有限HDR；验证真实遮挡、无阴影控制、LF独立与随时间变化。LF最大1.599609，保留源数值，没有错误截到1。 |
| `compute-v1` | 失败 | 体积纹理缺少 `TEXTURE_USAGE_CAN_COPY_TO_BIT`，清空时报40条引擎错误。进程exit0不代表通过。 |
| `compute-v2` | 未完成数值验证 | GPU runner无错误，但输出缺少分析器预期的`cases/`目录层，CPU比较找不到10组文件；`cpu-comparison/gpu-validation.json` 为false。 |
| `compute-v3` | 失败 | 输出路径修正后，2组的3项独立滤波检查共有8个分量超过预先固定的1 half-ULP门槛，最大2 ULP。保留硬件滤波版本和差异数组。 |
| `compute-v4` | 通过限定计算门槛 | 同样10组、40项raw SH与“从GPU raw重新计算”的独立filter检查全部≤1 half ULP；超过1者0。把原八个半体素三线性样本展开为float32精确texel读取再半精度写回，边界与权重不改。 |
| `compute-v5-runner` | 通过运行器闭环 | 使用更新后的运行器自动执行GPU及独立CPU分析；3.312秒完成引擎运行，exit0、无引擎错误，engine_passed/cpu_passed/passed均为true。计算门槛与v4相同。 |
| `receiver-v1` | 失败 | 瀑布两个表面实际共享1份材质，原数量断言错误；另游仙村默认机位冻结baseline、旁路、恢复帧不完全相等。无引擎错误。 |
| `receiver-v2` | 失败 | 修正共享材质计数、增加单目标材质比较和游仙村上游缓冲诊断；只剩游仙村默认机位上述3项失败。SmokeSubUV此版尚无独立可见机位。 |
| `receiver-v3` | **未通过整套检查** | runner exit1，342.828秒，无引擎错误；增加SmokeSubUV单目标机位并同步冻结室内LF，仍只剩游仙村默认机位baseline/旁路/恢复3项失败。 |

计算通过的范围必须保留：v4验证的是 **raw注入及以同一GPU raw为输入的独立滤波**，不是整个CPU→GPU端到端全过程≤1 ULP。端到端差异另存，有3 ULP等累计误差，未通过扩大阈值把它改写成逐值相同。64次texelFetch替代8次硬件采样尚无实时性能承诺。原始输入、结果和差异数组都留在对应版本目录。

v3在无名岛每个视图绑定28份唯一材质：Ocean1、Water1、Waterfall1、Smoke1 11、SmokeSubUV5、Splash9；游仙村为Ocean1、Water1。六族都有独立目标材质开启/禁太阳的非零画面贡献，且无名岛7个状态、游仙村Water与inside-state共9个视图的冻结baseline、旁路、恢复比较通过。Water在无名岛此机位仅101个通道变化，证明存在贡献，不证明构图/美术可读性已合格。游仙村default的baseline重复已有17个通道变化、最大11/255，在安装receiver之前出现，所以不足以指控receiver回归，也不能忽略或提阈值宣称全套通过。所有restore返回无所有权错误。

v3独立CPU复核完成10机位、20级体积的全部raw注入和隔离滤波检查，均满足上述1 ULP门槛，40份Texture3D上传记录逐层回读与原字节一致。整体仍因同三项画面检查失败，不把计算通过改写成接入通过。

旧 receiver-v2 阶段诊断保留的深度、CoC、景深混合权重和独立粒子层相同，变化已在景深前 HDR 出现。但其所谓时间切片来自错误偏移 2832，只能证明曝光等字节相同，不能验证真实 Shader 时间；这项旧结论现已撤回。该版异步捕获没有共享帧 ID，不将其跨阶段数据误说成同帧关联。后续同回调三阶段定位和完整 UBO 证据见下文。

主证据为 `workbench/reports/tlv-shadow-20261126/{probe-v1,scene-v1}/cpu-validation.json`、`compute-v*/runner.json`及`cpu-comparison/gpu-validation.json`、`receiver-v*/{runner,receiver}.json`与`receiver-v3/cpu-comparison/receiver-cpu-validation.json`。

## 时间读取修正与水面动态

旧水折射和 receiver 诊断将 Scene UBO 的 byte 2832 误读为 TIME；当前 Godot 4.7.2 float 缓冲实际为 5696 字节（2848×2），当前 TIME/TAA/jitter 位于 2816/2820/2824/2828。2832 是 emissive exposure，因而旧 `TIME=1.0` 及仅 16 字节切片的“实际时间已验证”结论撤回。旧深度、CoC、独立粒子层和精确恢复图像观察分别保留，不能拿它们补证时间读取。

这一错误也进入了实际渲染：两份水折射 GLSL 使用 `preceding[177]`，使涌浪和六组法线滚动读取曝光，与主水材质的 TIME 不同源。现已部署为 `[176]`，同时保留完整 UBO 并严格标记布局；未知布局不生成已验证时间。水主材质公式、原参数与几何保持。

`water-clock-20261126/gpu-v1` 已完成：228.359 秒、exit 0，引擎错误/警告为 0；两图真实时钟、动态响应、源状态和冻结恢复图像检查通过。无名岛 TIME 从 102.03333282470703 到 115.78349304199219，累积变化 94,812 像素/192,109 字节；游仙村从 181.74180603027344 到 190.5485076904297，变化 27,112 像素/42,521 字节。各图 432 字节 Water frame 在双时刻完全一致。

独立 CPU 复核确认六份完整 UBO 的切片/时间及 TAA/jitter，六组 HDR 有限、零累积区逐位不变。沿用旧公式和误差界限，float64 与 float32-div 六组均通过；float32-recip 在无名岛三组底行 y=719 仍有 137/137/292 个分量超界（合计 566，内部为 0），游仙三组通过。因此 `raw_clock_dynamic_passed=true`，但三种数值模型的 CPU 综合结果仍为 false；没有遮掉边界或放宽界限。这一边界算术模型差异尚未证明 GPU 实际采用哪种指令，不能改写成整套数值验证通过。

验证保持 CPU 场景禁用，只推进 Shader 时间后再冻结；其他使用 TIME 的材质也会推进，累积变化并非水独立因果或原 UE 等价的证明。本次游仙恢复通过不取消其他运行的冻结漂移失败。详细结果见 [水折射时间修正](WATER_CLOCK_PROGRESS_20261126.md)。

## 游仙村冻结漂移：当前定位

新捕获在每次回调保存 POST_OPAQUE、PRE_TRANSPARENT 大气前/后三阶段 HDR、深度及完整 UBO，并核对 frame/token/serial。比较只在同一诊断条件内部进行；没有放宽完全一致门槛，也没有将关灯、关阴影、关 LF 或 unshaded 当作生产修复。

| 对照 | 观察 | 当前边界 |
|---|---|---|
| `stage-v2` | 12 帧的 66/66 对最早均在 POST_OPAQUE 不同，最多 123 个像素；深度、完整 UBO 与折射累积全部相同。 | 最早来源在不透明阶段；本轮排除大气、透明绘制、折射和景深作为首发阶段。 |
| `shadow-controls-v1` | 原状态、仅太阳/仅局部/全部关阴影、恢复各四帧，组内均 6/6 对不同；全关阴影仍有 45 个变化像素的并集。 | 不能把全部漂移归因阴影。 |
| `unshaded-controls-v2` | 275 个材质临时保留原几何与 fragment，仅追加 unshaded；其四帧 HDR/最终图完全一致，原状态和恢复组仍不同。 | 定位到受光相关路径，未找到真正根因；v1 超时仍保留。 |
| `lf-controls-v1` | 原状态、太阳 LF 关闭、全部 LF 关闭、恢复各 6/6 对最早在 POST_OPAQUE 不同；变化像素并集分别为 60/73/42/95。 | 全 LF 关闭仍有最大 HDR 分量差 3.267333984375，不能概括成半精度量化误差；关闭 LF 不足以消除漂移。 |

LF 对照的 48 份完整 UBO、48 份深度与 16 份折射累积分别逐字节一致；TIME=55.849998474121094，TAA/jitter=0。275 个材质最终参数恢复检查通过；原运行未序列化每材质的应用值或 GPU uniform buffer，关断证据为保存的 setter 实现和完整执行，不称独立 GPU 参数回读。Scene UBO 相同仍不证明 light、cluster 或 shadow 内部输入相同。

完整 UBO 重解还确认 `stage-v2` 的 TIME=63.89590835571289，36 份缓冲全部一致。此证据独立于旧 receiver 的错误 16 字节切片；旧阶段采集缺共享帧 ID 的局限也保留。数据在 `workbench/reports/tlv-drift-20261126/`，失败与未定位项不删除。

## 主相机 caster 候选

风动植被只绑定主相机距离，固定 Y billboard 只绑定主相机朝向；保持原 pass 矩阵、尺寸、UV、fragment/mask/discard 与材质恢复。无名岛严格预检完成 165 项绑定（Wind 130、AmbientLitFixedY 34、Hero 1），unsupported=0。必须先停 probe，再恢复绑定，最后关闭 renderer。

`wuming-v2` 近级两次启用采样有 4/262144 个 R 阴影值不一致，差为 ±0.00390625，整次失败，不能记作 1 half ULP 或放宽门槛。`wuming-v3` 加入同步 UBO 观察后，两级各四次启用重复均逐位一致，禁用/恢复控制通过；但观察本身可能改变时序，不能据此称 v2 根因解决或无条件确定性成立。v1 解析失败亦保留。

v3 的 40 份主视图/probe 完整缓冲按正确布局重解：TIME=94.98445892333984，TAA/jitter=0。主视图完整 UBO 稳定；probe 同级缓冲仅 byte 2660 的 `radiance_border_size` 变化，不将整个 probe UBO 误记为一致，也没有证据表明该字段造成阴影差异。候选和复跑工具已进入独立工程，但默认行走未启用，尚未证明原 UE 投影/dither 对等。数据在 `workbench/reports/tlv-caster-20261126/`。

新增 `youxian-v1` 运行 79.812 秒、无引擎错误，完成 208 项绑定（Wind 133、AmbientLitFixedY 74、Hero 1），unsupported=0。两级各四次启用采样重复逐位一致；baseline 重复、禁用和 probe 后禁用图像也一致。最终恢复仍有 7 个通道不同、最大 2/255，故引擎诊断/CPU/整套均为失败。材质、几何参数恢复检查通过、owner.remaining=0，不能把状态恢复与最终画面完全一致混为一谈，也不能据此将变化直接归因于绑定。

2026-11-27 独立 CPU 复查：恢复差异为 5 像素/7 通道，范围 x468–477、y106–114。后续逐点定位纠正了“均落在旧 all-LF-off 漂移区域”的描述：这 5 个最终 PNG 坐标没有直接命中旧 all-LF-off 的 42 个 POST_OPAQUE 变化坐标。它们来自不同运行及阶段，时间、材质状态和相机高度也略有不同；不能仅凭附近看似植被的屏幕区域判定实际树叶材质或相同成因。40 份完整 UBO 按各 cascade/view 分组稳定，真实 TIME=57.95665740966797；不同视图的缓冲不能合称为一份相同数据。状态恢复依赖运行时断言，未保存全部 post-restore 参数快照供 CPU 独立重放。原复查保存在 `workbench/reports/tlv-caster-20261126/youxian-v1-cpu-review/`，后续坐标核对见 `workbench/reports/landscape-drift-20261127/lighting-input-audit-v2/`；7 通道恢复失败结论保持。

## 复跑

使用已配齐本地资源的独立工程、同版本Godot及带NumPy/Pillow的Python，在仓库根运行，输出目录必须不存在：

```powershell
python tools/verification/run_source_tlv.py probe workbench/reports/tlv-new-probe
python tools/verification/run_source_tlv.py scene workbench/reports/tlv-new-scene
python tools/verification/build_source_tlv_inputs.py --source workbench/reports/tlv-new-scene --out workbench/reports/tlv-new-inputs
python tools/verification/run_source_tlv.py compute workbench/reports/tlv-new-compute --inputs workbench/reports/tlv-new-inputs
python tools/verification/run_source_tlv.py receiver workbench/reports/tlv-new-receiver --timeout 480
```

运行器只管理自己启动的进程，保存输入代码哈希；最终结果同时要求引擎状态与独立CPU数值/图像分析通过。早期v1–v4的运行器只汇总引擎，须一起读当时的独立CPU报告。局部灯`probe --local-probe --force-shadow-refresh`仍只有控制实验，不自动冒称完整局部灯数值对等。

主相机绑定与漂移采集工具也已入仓，可单独执行：

```powershell
python tools/verification/run_source_tlv_caster.py --map wuming --out workbench/reports/caster-new-wuming
python tools/verification/run_source_tlv_caster.py --map youxian --out workbench/reports/caster-new-youxian
python tools/verification/run_source_tlv_drift.py --direct-youxian --out workbench/reports/drift-new-stage
python tools/verification/drift/analyze_upstream_drift.py --run workbench/reports/drift-new-stage --out workbench/reports/drift-new-cpu
```

漂移运行器的 `capture_passed` 只表示采集完成；冻结相等性必须另看 CPU 分析。`--shadow-controls`、`--unshaded-controls`、`--lf-controls` 及新增 landscape 控制选项互斥，仅按新假设选用。旧模式入仓时只完成 wrapper 静态/命令行检查，其既有 GPU 证据来自同内容诊断脚本的暂存入口，保留这一历史边界。2026-11-27 新增的 `--landscape-controls` 和 `--landscape-specular-controls` 已通过正式 wrapper 实际运行 GPU，不能再笼统描述为 wrapper 未实测；证据与仍未解决的漂移见 `LANDSCAPE_PROGRESS_20261127.md`。水时钟复跑见 `WATER_CLOCK_PROGRESS_20261126.md`。

## 未完成的内容

- **主相机 caster 一致性。** 无名岛 v2 重复失败与 v3 加观察器通过并存；游仙村首次扩展的两级重复通过，但最终恢复 7 通道不同，整套失败。还需确认观察器影响及恢复画面差异，再扩大位置；不能称原版全 caster 一致，也不能直接接入默认入口。
- **实时更新。** 当前接收器消费冻结快照；相机bounds、时间、LF、太阳/室内状态变化后还没有持续更新、失效、预算及完整frame freshness方案。两级体积快照不能直接放到可走动场景中长期复用。
- **局部灯 TLV。** 目前仅太阳注入。局部Omni探针的缓存失效已有独立控制试验（v5使用owned clone `shadow_enabled=false→true`），但源Spot投影/源ID/逐灯贡献与两级体积尚未实现；当前局部光仍是既有表面路径。公开atlas接口补丁也未编译。
- **原生对等与美术验收。** 方向阴影仍使用独立Godot PSSM与8位attenuation，粒子LightingPositionOffset为零诊断，原UE原生体积/CSM未逐像素对照；当前技术结果不代表两图完整复原或用户已认可画面。

## 下一步按这个顺序执行

1. **保留已修复的水时钟与数值边界记录。** 真实时钟及两图动态/冻结恢复已通过。float32-recip 是另一个 CPU 运算模型，其底行差异尚不能认定为生产渲染缺陷；保留综合 CPU false 与全部样本，不据此改原折射公式。后续若检查实际 GPU 指令，再核清其边界分支。
2. **继续定位游仙村不透明受光漂移。** 三阶段、阴影、unshaded、LF 控制已完成，无需原样重跑。按已有变化像素及世界坐标定位实际材质/实例，检查其实际受光输入；区分屋顶跳变和其他区域，不在无证据时改生产公式。问题解决后先复测该机位，再收口 receiver 整体报告。
3. **收口 caster 绑定的重复性与恢复画面。** 保留无名 v2 失败/v3 观察器通过及游仙 v1 恢复失败，核对相同机位移除/保留观察器的影响和游仙 7 通道变化，再扩大机位。状态恢复通过不能替代画面恢复检查；禁止关闭人物投影来获得一致。
4. **再做太阳两级体积的最小实时闭环。** 选短距离行走和一次进出屋，记录 bounds/frame/state；保证同一时刻两级原子替换、失效与 freshness，拒绝旧 bounds，随后测成本与更新预算。此前保持显式验证入口。
5. **随后接一盏具有源身份和 CastShadows 证据的局部灯。** 联通源 range/cone/LF 与 SH 贡献，用开关灯、关阴影和遮罩形变控制验证，避免重复太阳或现有局部表面贡献，再扩展集合。

更细源码审计与候选保留在本地工作报告和暂存目录。上述待办不能记为完整复原已完成，默认试玩仍未启用冻结 TLV 快照。
