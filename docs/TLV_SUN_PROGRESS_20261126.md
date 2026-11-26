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

游仙村v2阶段诊断确认：冻结基线、重复、旁路、恢复的实际Shader时间UBO字节相同，深度、CoC、景深混合权重和独立粒子层相同；变化已经出现在景深之前的HDR。该输入已经经过distortion，目前尚未采集其前后缓冲，不能排除折射累积或应用阶段。因此不能归因于接收器、Shader时间或景深随机核。具体上游来源尚未确定；异步捕获没有共享帧ID，不将跨阶段字节误说成同一帧关联。

主证据为 `workbench/reports/tlv-shadow-20261126/{probe-v1,scene-v1}/cpu-validation.json`、`compute-v*/runner.json`及`cpu-comparison/gpu-validation.json`、`receiver-v*/{runner,receiver}.json`与`receiver-v3/cpu-comparison/receiver-cpu-validation.json`。

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

## 未完成的内容

- **主相机 caster 一致性。** 植被风幅读取的 `CAMERA_POSITION_WORLD` 在阴影pass实际对应light camera；人物/NPC billboard读取 `MAIN_CAM_INV_VIEW_MATRIX`，在probe中变成probe机位。两者都会影响投影形状。已提供只锁植被主机位的可恢复候选并通过CPU检查，但未GPU运行；它对其他已知相机caster默认拒收。当前结果仍不能叫主画面同一形变、原版全caster一致。
- **实时更新。** 当前接收器消费冻结快照；相机bounds、时间、LF、太阳/室内状态变化后还没有持续更新、失效、预算及完整frame freshness方案。两级体积快照不能直接放到可走动场景中长期复用。
- **局部灯 TLV。** 目前仅太阳注入。局部Omni探针的缓存失效已有独立控制试验（v5使用owned clone `shadow_enabled=false→true`），但源Spot投影/源ID/逐灯贡献与两级体积尚未实现；当前局部光仍是既有表面路径。公开atlas接口补丁也未编译。
- **原生对等与美术验收。** 方向阴影仍使用独立Godot PSSM与8位attenuation，粒子LightingPositionOffset为零诊断，原UE原生体积/CSM未逐像素对照；当前技术结果不代表两图完整复原或用户已认可画面。

## 下一步按这个顺序执行

1. **只定位游仙村default的景深前冻结漂移。** 已排除实际Shader时间、深度和独立粒子层变化；先用现有distortion的`request_validation_capture`采集该机位折射前后缓冲，再根据首个变化阶段检查透明绘制与实际阴影输入，分开定位首次准备差异与持续往返的微小变化。保持原完全一致门槛，修复后先重跑该机位，再收口receiver整体报告。
2. **用一个固定有竹叶和人物的机位解决caster语义。** 先运行现成wind binding的严格预检，记录所有unsupported；实现原主相机固定Y billboard绑定并保持原mask/discard，继续保留原材质/参数完整还原。只比较同一冻结机位的caster轮廓、volume阴影与恢复帧；通过后再扩大两图机位。不要通过关闭人物投影得到假一致。
3. **做太阳两级快照的最小实时闭环。** 只选一段短距离行走和一次进出房，记录每次bounds/frame/state签名；先保证同一时刻两级原子替换及状态失效，拒绝旧bounds继续采样，再测成本决定更新预算。此闭环通过前保持显式验证入口。
4. **随后只接一盏有源身份和CastShadows证据的局部灯。** 将已验证clone visibility、源range/cone/LF和SH贡献联通，用开灯/关灯/关阴影/遮罩形变四组控制验证，确认不会重复太阳或当前局部表面项，再扩展灯集合。

更细的源码与候选位于本地 `workbench/reports/tlv-shadow-20261126/engine-api/receiver-readonly-audit/`。上述步骤均为接下来的实施项，不能记为本轮已经完成。
