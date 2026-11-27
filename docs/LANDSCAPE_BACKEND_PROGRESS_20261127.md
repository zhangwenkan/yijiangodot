# 游仙地形冻结漂移与后端实机对照

2026-11-27，本机同一游仙原地形诊断在 Vulkan 仍发生冻结漂移；显式 D3D12 对照的五组重复捕获全部严格一致，后续两图冻结 receiver/caster 回归也通过。然而四段正常速度行走显示 D3D12 在无名岛明显更慢，因此普通试玩仍保留现有默认后端，D3D12 作为显式选项与稳定性诊断使用。尚未确定是引擎、编译器、驱动或它们交互的哪一处根因，也未把诊断材质部署为生产修复。原 Fresnel 有限修正及刷新缓存的历史见 `LANDSCAPE_PROGRESS_20261127.md`；那轮修正没有消除本问题。

## 实际执行与数值结果

以下四次均已经完成真实 Godot 运行及独立 CPU 审计。每次五组、每组四帧，共 20 次捕获；表内数值是该次运行每组 POST_OPAQUE 四帧六对比较的变化像素并集，不是不同运行之间的差异。所有运行退出 0，wrapper 记录的引擎错误/警告列表为空。运行成功与冻结稳定性分别判断。

| 运行 | 耗时 | 五组 POST_OPAQUE 变化像素并集 | 独立 CPU 结论 |
|---|---:|---|---|
| `isolation-v1` | 138.828 秒 | 全图原态 110；仅地形原态 43；仅地形 raw-count 3186；仅地形恢复 132；全图恢复 113 | 证据有效，仍漂移 |
| `minimal-light-v1` | 107.656 秒 | 全图原态 50；count-marker 3062；minimal-light-marker 1934；仅地形恢复 80；全图恢复 51 | 证据有效，仍漂移 |
| `minimal-fragment-v1`（实际 Vulkan / Forward+） | 208.890 秒 | 全图原态 95；minimal-light-marker 2752；minimal-fragment-marker 2451；仅地形恢复 13；全图恢复 29 | 证据有效，仍漂移 |
| `minimal-fragment-d3d12-v1`（实际 D3D12 / Forward+） | 255.016 秒 | 五组均 0 | 本次全部冻结重复检查通过 |

前三次计数候选的最大单点计数变化均可达到 7，即原始计数 HDR 差 7/16 = 0.4375。不同 run 的变化像素多寡不代表相应代码使漂移改善或恶化。Vulkan 最小片元仍变化，说明仅移除原片元采样与材质计算不足以在该运行中消除问题；它不是已定位驱动错误的证明。

D3D12 的严格一致覆盖五组的全部五份 HDR、三份 depth、折射 accumulation 和最终 PNG，每组各六对比较均零变化。它包含全图原材质开头及恢复后的重复，也包含两个临时诊断候选。这里只断言每组自己的重复性；不声称两种临时材质互相等价，不声称全图与隔离图相同，也不声称 Vulkan 与 D3D12 的图像或 UBO 逐像素/逐字节等价。最终 PNG 晚于 compositor HDR 捕获，不能当作同帧采样。

## 对照如何限定变量

`verify_landscape_isolation.gd` 保留目标原地形的实际网格和原灯光，只临时隐藏其它 GeometryInstance3D。隐藏对象会改变阴影和遮挡，因此隔离图是归属诊断，不是全图的等价替代。原始 Compositor 对象身份保持，只在其效果数组插入观察器，最后还原原数组，避免 AfterDOF 可见性回调失去原 owner。

`verify_landscape_minimal_light.gd` 比较 count-marker 与 minimal-light-marker：原顶点、片元计算和最终中性覆盖保持相同，只把完整 `light()` 换为局部灯红通道加 1/16。它没有删除灯、删几何或借降低画质修复默认场景。

`verify_landscape_minimal_fragment.gd` 继承上述已验证初始化和恢复路径，只比较 minimal-light-marker 与 minimal-fragment-marker。后者将完整 `fragment()` 替换为白色 ALBEDO、零金属/镜面、粗糙度 1、固定法线、AO 1、零 AO 灯光影响、黑色 IRRADIANCE/RADIANCE 和相同 marker；两候选仅完整片元函数的源码字节不同，原顶点、相同最小 light、辅助声明和全部 70 个 uniform 保留。完整源、变换前后函数、逆变换精确结果及哈希均保存。

marker 的 R 是局部光调用次数/16，G 是当前片元屏幕 tile 编码，B 是显式 geometry stamp 和当前片元深度切片编码。G/B 经 EMISSION 输出，因此零次局部光调用仍被覆盖。stamp=1 显式对应唯一原地形节点及材质。它们不是 GPU 内部 cluster buffer 或实际材质/primitive ID 的读回，不能用这些编码补称此前 RenderDoc 已失败取得的证据。

两次 minimal-fragment 运行中，各有全屏 518400 个有效 marker 点；各自八帧候选的 G/B 与深度域一致。D3D12 的 619 个同帧标记分组在时间维度上也全部保持计数；Vulkan 的最小片元仍有 112 个分组随帧变化。归组从各自新捕获重新计算，没有复用旧变化坐标或排除零计数/不利像素。

## 输入、后端和恢复证据

四次运行均复核 370 份材质、目标 70 个参数、32 盏原灯及 2147 个几何对象的 CPU 可见状态与恢复；最终材质、灯光和几何快照保持，controller/time_scale 与 Compositor 恢复通过。isolation 为 43 次场景状态与 5 次材料核查；三个含双候选的后续运行分别为 43 次场景状态和 9 次材料核查。此处是引擎暴露状态，不是逐项 GPU uniform、light buffer 或 cluster buffer 回读。

每次 60 份上游完整 Scene UBO 和 20 份折射完整 UBO 分别在自己的组内严格一致；上游组与折射组不得混称全体 80 份相同。完整场景与隔离场景的深度本就不同，深度稳定性按相应可见性条件和受控候选比较，不跨条件强行套一致结论。

marker 只从同次运行首份 POST_OPAQUE 的 5696 字节 UBO 取得有限正数 z_far（偏移 2680），emissive gain（偏移 2832）必须严格等于 1；20 次捕获的 80 份 UBO 均再次校验。没有把旧报告常量替代本轮实际值，真实 TIME 布局沿用已更正的 2816 偏移。

两次 minimal-fragment 均要求恰好一个 `--diagnostic-driver=vulkan|d3d12`。每次 64 项 RenderingServer 实际 driver/method 观察都通过：actual driver 与明确期待值一致，method 为 `forward_plus`，避免把自动回退误认指定后端运行。实际 D3D12 引擎 banner 为 `D3D12 12_0 - Forward+`，设备 AMD Radeon 780M Graphics。该结论限定本机这次测试；仅从此对照不能承诺其它 GPU、系统或长期运行同样稳定。

## 两图冻结 receiver 与 caster 回归

`receiver-d3d12-v1` 为 328.297 秒、退出 0、引擎错误/警告空。独立 CPU 审计覆盖两图十机位二十 cascade，80 个 raw/isolated-filter 数值门槛全部通过，最大 half ULP 距离为 1，超过 1 的分量为 0。40 个端到端比较单独记录，最大为 3，没有借此放宽原 raw/isolated 门槛。76 张 PNG 中 30 个原态/关闭/恢复对照严格一致，十个太阳光贡献及八个指定材质的太阳受光贡献非零。游仙 default 的四次冻结快照在各保存 stage/field 的六对比较中全部严格一致，实际 current/previous clock、DOF 等冻结状态也复核。

该 receiver 运行 24 次实际 driver/method 均为 D3D12 / Forward+，28 份 source inputs 和部署脚本基线保持。40 次 64-slice 上传一致性是运行时 byte-exact 断言；GPU 上传回读字节未另存为独立文件。202 条材质保持记录是运行时断言，没有完整前后所有参数快照。各 stage 没有共用帧 ID，不能扩展为跨 stage 同帧等价。它仍为冻结 sun-only 路径，不能称为完整实时 TLV 或原 UE 像素等价。

两图 `caster-wuming-d3d12-v1` / `caster-youxian-d3d12-v1` 分别运行 124.593 / 153.485 秒，退出 0、引擎错误/警告空，独立 CPU 均通过。无名岛核对 165 份材质（Wind 130、AmbientLitFixedY 34、Character 1）、11653 个原参数及 3701 个几何运行时断言；游仙村为 208 份（133、74、1）、13919 参数及 2147 个几何断言。每图五次实际后端观察全部 D3D12。

每图六张 PNG 的四个严格控制对照均零变化；十份 HDR 的十二个完整 enabled 配对均 exact。每图四十份完整 5696 字节 Scene UBO 的哈希、布局与 token 通过，同一 view 捕获前后 frame 和字节一致，current/previous clock、TAA 与 jitter 冻结通过。owner 冲突按 N−1 再恢复 1 的过程验证。绑定开启后无名/游仙 PNG 分别有 46548/49313 个通道变化、最大 101/78；near/far shadow 分别有 98/3 与 585/37 个变化样点，LF 为 0。这些说明存在作用，不是质量改善门槛。原参数快照已保留，最终参数恢复仍依赖运行时断言及 PNG 证据，没有独立最终参数快照；不声明 UE 阴影等价或生产完成。

## 两个入口与正常速度行走

启动器 `tools/launch_godot_world.ps1` 已部署可选 `-RenderingDriver vulkan|d3d12`。显式驱动同时传给导入器及游戏，要求实际引擎 banner 确认所选后端和 Forward+ 后才记 READY；显式选择会开新窗口以避免复用未知后端的旧进程。默认仍是空字符串，沿用原项目后端，不部署曾准备的默认 D3D12 候选。两个 CMD 原本即以 `%*` 转发参数，文件未改。

两个真实 CMD 的显式 D3D12 启动均达到可试玩 READY、落地有支撑，保存 1280×720 图并正常退出，独立 CPU 十六项检查通过。证据为 `artifacts/wandering-original-worlds-review/launch-logs/20261127-220334-959-wuming-verification.json` 和 `20261127-220605-823-youxian-verification.json`。这只确认入口、后端和画面生成，不替代走路或舒适性检查。需要显式对照时可运行 `"F:\逸剑godot\试玩Godot无名岛.cmd" -RenderingDriver d3d12`，游仙村入口同理。

随后使用同一原镜头、输入路线、1280×720 Forward+ 与全部现有原效果，分别实跑 D3D12 和 Vulkan 的栈道、台阶、无名房屋往返、游仙房屋往返四段。没有 headless、固定帧率、录电影或逐帧 PNG 读回；每次实际 draw 都观察到 `time_scale=1`。六份源码哈希、四段路线定义及调用参数（仅后端与证据路径不同）完全相同。所有阶段均实际绘制，支撑无缺失或越界，两条房屋路线各完成两次进出；每段只有一次起点放置，没有中途传送。原镜头的 8/s 水平、3/s 竖向跟随保持，未借此声称镜头不适已修复。

| 段落 | D3D12 / Vulkan 实际 draw 数 | D3D12 / Vulkan 观察帧率 | D3D12 / Vulkan p95 间隔 | D3D12 / Vulkan 模拟/墙钟 |
|---|---:|---:|---:|---:|
| 无名岛栈道 | 67 / 148 | 6.439 / 16.882 draw/s | 185.711 / 69.628 ms | 0.8443 / 0.9955 |
| 无名岛台阶 | 68 / 153 | 6.282 / 17.196 draw/s | 187.469 / 67.471 ms | 0.8238 / 1.0010 |
| 无名岛房屋 | 75 / 166 | 6.059 / 16.603 draw/s | 194.033 / 72.781 ms | 0.8061 / 0.9980 |
| 游仙村房屋 | 241 / 297 | 25.154 / 31.014 draw/s | 74.676 / 38.213 ms | 0.9991 / 1.0002 |

帧率来自每段首末 draw 之间的实际墙钟间隔，p95 采用线性插值。此为单次配对、含 CPU/JSONL 观察开销的诊断，不能当作生产性能基准；加载和编译使 wrapper 总耗时不适合换算帧率。即使 `time_scale=1`，D3D12 无名岛三段的模拟也未跟上真实时间。Vulkan 相对较快仍不代表流畅验收。因此默认保持，后续须定位帧成本；不能以关闭原效果、缩小地图或放宽稳定性门槛代替复原。

两次严格整 run CPU 审计各为 109/110，唯一失败明确保留：最终报告之后、退出之前各多写一条空场景 draw，D3D12 报告 583/文件 584，Vulkan 报告 896/文件 897；追加行分别在最终摘要时间 115.419585 / 107.218957 秒之后的 115.434005 / 107.227132 秒，均无 case。四段记录及全部 phase 数据未丢失，独立配对证据十六项通过，但不能将整 run 审计改写为通过。V2 已部署，仅在最终保存前断开该观察信号再 flush，保留原路线和驱动；部署哈希为 `b44306dfd69b61d6a59ce5a8fee3d7292368b6ac9bfd5fc0724a6f963ae8ce6a`。V2 解析 1.609 秒、单个游仙房屋案例 Vulkan 实跑 95.265 秒均退出 0、错误/警告空；独立 CPU 48 项全通过，最终摘要与原始流严格同为 131 条，末条 90.313651 秒早于摘要 90.313801 秒，92 个案例 draw 覆盖全部阶段、支撑及两次进出通过。这只完成收尾复核，不重写 V1 失败、不称两后端四段重跑，也不由本次单案例新增性能结论。

## 当前生产边界与后续

这一轮新增三个地形诊断、receiver/caster 后端检查和四段行走观察脚本及可选后端启动参数，保留既有生产材质、几何、光照和项目默认后端。没有将 raw-count、最小 light 或最小 fragment 接入普通试玩，没有重试已失败的 RenderDoc 路线。旧失败与原始证据继续保留。后续实时 TLV、动态投影、常规帧成本及原版视觉比对仍须独立完成，未运行候选与未完成回归不能提前记为完成。

本次冻结诊断通过不等于完整 TLV 已接入、原版 UE 像素等价、地图行走与镜头舒适性通过、性能改善或用户美术验收。原完整复原目标和现有未完成项继续有效。

## 本地证据与小文件提交边界

GPU 与 runner 证据均在 `workbench/reports/landscape-drift-20261127/`：`isolation-v1`、`minimal-light-v1`、`minimal-fragment-v1`、`minimal-fragment-d3d12-v1`、`receiver-d3d12-v1`、`caster-wuming-d3d12-v1`、`caster-youxian-d3d12-v1`、`playable-camera-d3d12-v1`、`playable-camera-vulkan-v1` 及相应 runner 目录。四次地形独立 CPU 已归档为 `isolation-cpu-v3`、`minimal-light-cpu-v1`、`minimal-fragment-cpu-v1`、`minimal-fragment-d3d12-cpu-v1`；receiver/caster 为 `receiver-d3d12-cpu-v1`、`caster-wuming-d3d12-cpu-v1`、`caster-youxian-d3d12-cpu-v1`。来源及哈希保存于本次 docs stage 的 evidence manifest，行走与入口 CPU 复核的位置亦逐项列入。

Git 只加入六个新诊断 GDScript、已部署启动器、此文和 AGENTS 短摘要；实际 observer 版本以部署后的哈希清单为准。PNG、raw、完整 UBO、NPZ、大型 JSON、派生资产、Godot 缓存、引擎和本地分析报告不随此提交；清单外 `.uid` 不因本轮顺带加入。提交与 push 的实际结果由主代理另记，不用候选准备代替远端同步。
