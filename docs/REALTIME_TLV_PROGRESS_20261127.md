# 实时太阳 TLV：旁路生产、实际数值与发布验证

阶段记录，2026-11-27 启动，2026-11-28 封存；V3 receiver、V4 新 pair 数值与两图连续穿门的独立审核均已封存。目录和文件名保留启动日期。

本轮将实时太阳体积推进到可观察的 receiver 发布、受光贡献、恢复以及两图真实进出房屋，但开启后的运行成本不可接受，默认试玩继续关闭。局部正确性推进不能记作完整功能目标已完成。V1/V2 实跑保持 receiver 关闭，V3 与穿门诊断才通过显式参数启用；没有将实时体积接入 `worlds.gd`、启动器或默认试玩。体积当前只含一个方向太阳，局部灯仍沿用现有逐片元路径，局部灯 TLV 尚未实现。后端选择及已有地形冻结漂移另见 `LANDSCAPE_BACKEND_PROGRESS_20261127.md`，本工作没有因此改变默认后端。

## 实现范围

独立代码位于 `project/source_tlv_realtime/`，入口为 `scripts/verification/verify_realtime_sun_sidecar.gd`。两个常驻探针共享原场景和既有绘制资产，分别生成近、远 512² 图集；图集取得当前 Godot 太阳阴影及原 LightFunction。主 RenderingDevice 直接解码到 64³ 体素、注入太阳 SH 并执行原过滤，生成近远各 ambient/directional 四张 Texture3DRD。没有新建模型，也没有以常量白光代替缺失阴影。

当前一次只有一个 pair 在途，三个 filtered slot 和两张共享 raw scratch 常驻。正常路径每 pair 异步读取 192 字节状态；每 cascade 初始化另读一次完整 5696 字节 Scene UBO 检查布局。近远必须是相同实际 draw frame，current/previous TIME、TAA、jitter 位模式一致，身份、generation、mask、体素计数及年龄须通过；不是仅比较 CPU 请求时间，也不要求近远整份空间 UBO 相同。

完成的组带着自己的四纹理、双 bounds 与 generation。主线程发布设计在一次无 await 的 pre_draw 批次完成，代码和 ACK 不能单独证明 GPU 的每个可见 draw 都消费同一 epoch，更不能称为 Godot 多材质原子事务或同帧生产、同帧消费。地图、房屋、owner 变化与过期数据的处理及最终 receiver 画面仍要分别验证。

## V1：正常生命周期

`realtime-sidecar-d3d12-v1` 在无名岛实际使用 Godot 4.7.2 / D3D12 / Forward+，wrapper 45.094 秒、退出 0、错误/警告空。依次经历户外、室内、回到户外，累计 produced 8、house 切换 rejected 2、published 0，receiver=false。三个阶段保存的代表 ACK 各 192 字节，近远各 96 字节的身份、时钟、generation、mask、方向光计数及请求帧通过，三个阶段 TIME 递增。它没有保存全部八组 ACK，不能将三份代表记录称为八份逐个独立复算。

独立 CPU 审核 17 项正反测试通过。两份初始完整 5696 字节 UBO 的原始 clock/gain/alpha/mask 字段与对应状态关联通过；它们不是后续三个 ACK 的同帧完整 UBO。停止记录为恢复 165 个材质、剩余 0，caster/receiver/probe 错误空，gpu_closed=true、cleanup=closed；不是仅发出 queued，也不是独立枚举了全部 GPU 资源。11 候选、11 依赖及作者/部署 manifest 哈希通过；审核时已升级的五文件通过 V2 before 备份衔接，未将当前 V2 冒称为 V1。

V1 证明的是正常 API 与生命周期，没有保存新 compute 的完整数值输出，也没有 receiver 发布、整图视觉或所有异常路径验收。

## V2：实际新 pair 的固定门槛数值

V2 parse 1.140 秒、`realtime-pair-d3d12-v2` wrapper 87.031 秒，均退出 0、错误/警告空。仍为无名岛 D3D12 / Forward+、receiver=false、published=0。新增逐请求有界历史、初始化资源检查、材质 owner 保护及太阳阴影属性指纹，并通过显式 `--diagnostic-once` 捕获首个实际 pair。诊断模式有同步完整读回，会扰动运行时间；这些秒数不作实时性能基准。

本次 11 请求对应 11 完整 192 字节 ACK，逐个核对为 8 accepted、2 进出屋取消、1 停止后的退休确认。所有近远 pair 的实际帧与 current/previous clock 位一致，TIME 持续推进；每次请求只对应一次完成或退休。正常停止恢复 165 个材质且无遗留条目，GPU closed 已确认。11 候选和 11 依赖的哈希、输入与来源审核前后哈希保持。

完整数值取样仅为 snapshot 1 / actual frame 42 的近远一组。保存 14 文件：每 cascade 六份 atlas、完整 UBO、raw ambient/directional、filtered ambient/directional，加状态和元数据。所选 ACK 的 clock/gain/mask 与对应完整 UBO 原始字节一致；历史、元数据与运行内嵌副本的 snapshot、bounds、camera、generation、slot、frame 及精确数值 radiance/direction 对齐。每级文件清单严格属于本级，不能交叉替换。图集和 raw/filtered 从本次真实计算目标取得，没有使用旧 fixture 或 CPU 结果替换 GPU 输出。

| 数值范围 | 检查数 | 实测结果 | 判定方式 |
|---|---:|---|---|
| 两级 raw ambient/directional 与 CPU 参考 | 4 | 最大相邻 binary16 ULP 距离 1，超 1 分量 0 | 保留 ≤1 门槛 |
| 从 GPU raw 开始的 isolated filter | 4 | 最大距离 1，超 1 分量 0 | 保留 ≤1 门槛 |
| 端到端 filtered 观测 | 4 | 最大距离 3 | 单列记录，不提高前述门槛 |

13 项独立正反证据测试与冻结作者脚本的 24 项 CPU fixture 通过。公式保持 atlas 8×8 tile 到 64³ 的映射、实测 shadow×LightFunction、原 far 边缘渐淡、原 SH 编码，以及 raw half→filter half 的舍入边界。数值通过是容差内一致，不是全部体素逐位 exact；只有一组新 pair 完整复算，不覆盖所有 11 pair、全地图位置或全太阳状态。

精确 radiance/direction 与 bounds 来源为 snapshot 和作者代码；未另存其 GPU push constants 或完整光栅材质上传字节。当前阴影是 Godot 的实测阴影，尚无原生 UE shadow atlas 等价证据。

V2 静态审阅发现两类未覆盖分支：retry 可能遗漏 probe 的 owner 冲突状态，diagnostic/dispatch 的部分资源分配或更新返回值还未完整转为失败。这些不影响已保存的正常路径通过，但正常取样不能证明异常分支已安全结束。V2 原封存不回写；V3 修正前一类，后一类仍须另行覆盖。

## 游仙村 V2：状态切换生命周期

`realtime-sidecar-youxian-d3d12-v2` 实跑 48.891 秒，退出 0、错误/警告空，独立 CPU 十二项正反测试通过。11 请求/11 完整 ACK 逐个核对为 8 accepted、2 house 取消、1 stop retirement；全部近远 current/previous clock 字节一致、TIME 递增，本次接收年龄均两帧。house generation 0→1→2，owner generation 0→2→4，两份初始完整 UBO 与首 pair 对应字节通过。

caster 覆盖 208 材质（Wind 133、AmbientLitFixedY 74、CharacterFixedY 1），unsupported 空；退出恢复 208、剩余 0，caster/receiver/probe 错误空且 GPU closed。11 候选与 11 依赖的来源哈希通过。receiver=false、published=0。此处直接调用 `set_inside(true/false)`，不是实际穿门；没有 full atlas/raw/filtered 取样，不另称游仙新 compute 数值通过。

## V3 receiver：受控冻结与正常时钟

14 文件候选已部署，作者 manifest 为 `5893da1fb63141259f3e08681ead001c7acc4768ba051bd6aab4547576a0ea64`。原十一文件只有 `retry_restore_shutdown()` 改动：重试尚未恢复的 probe，将 probe/receiver/caster 错误共同纳入终态，并保持已经确认的 closed；新增三文件均为显式诊断。默认试玩和原生产计算不因此接入 receiver。解析 2.031 秒、无名 D3D12 frozen 120.015 秒、normal 93.562 秒均实际退出 0、错误/警告空。独立 CPU 十三项正反测试与作者十五项 fixture 通过，十四候选与十一依赖哈希保持；两种模式的原始二进制和图像均重新核对。

Frozen 诊断关闭场景处理、time_scale=0，通过专用 owner 持有首个完整 publication，并暂停普通八帧年龄策略。这是明确的冻结例外，不是正常动态政策。十份捕获依次覆盖原态及重复、caster-only 及重复、receiver mode0、mode1及重复、mode2去太阳、mode0返回和完整卸载恢复。receiver 的旁路严格对照 caster-only，因为相机相关 caster 修正本身会改变阴影；全卸载后才与最初原态比较。不能把 caster 引入的真实差异误归 receiver，也不能因此取消它的对照。

独立 CPU 审计的六个 HDR/PNG 严格重复/恢复对照均零变化，mode1 相对去太阳有 207063 个 PNG 通道及 211884 个 HDR half 分量变化，HDR RGB 最大绝对差 1.0283203125；这些说明太阳路径实际有作用，不是画质优劣的门槛。覆盖 28 个 receiver 材质：Ocean 1、Water 1、Waterfall 1、Smoke1 11、SmokeSubUV 5、Splash 9。27 次 pre_draw 提交使用同一持有 token，共 756 份材质观测，保存 CPU uniforms、四张纹理身份、双 bounds 与 mode，并和实际主视图 draw/完整 UBO 关联。这还不是 GPU 每片元 epoch 的标记读回，不能声称跨材质 GPU 原子发布。

冻结运行另外注入临时主相机 cull-mask 外部 owner 冲突：stop 保持外部 mask，retry 在冲突未解决时必须继续报告 probe 错误，closed 不能回退 queued；归还该测试改动后才允许恢复原 mask。该项针对 V2 确定的 retry 缺口，不代表已覆盖所有资源分配、设备丢失或 owner 故障。

Normal 使用普通生产器、time_scale=1 和原八帧年龄策略，捕获四个不同 publication，四次提交共 112 份材质 CPU 状态核对通过。五请求/五完整 ACK 为四个 accepted/published 和最后一个已完成后的 stop retirement，最后未取消不等于遗漏清理。主视图 shader TIME 减生产 ACK TIME 的实测差依次约为 1.0500、4.7153、1.0082、1.1932 秒，观察帧年龄为 2、1、1、1；小帧数年龄不等于低时间延迟。此处相机固定，没有 `set_inside()` 或连续走路；同步大规模 HDR/UBO/PNG 诊断读回扰动明显，不能据此称正常路径低延迟、流畅或性能通过，也不能直接当默认试玩基准。主视图与新建 probe 的 previous TIME 可能不同，按真实关系保存，不要求它们整份 UBO 相同。

## 两图实际连续穿门与性能问题

新增独立 `scripts/verification/diagnostics/verify_realtime_house_route.gd`，源码哈希 `c9427fbf4ac546f6cb457ec4ee7cc4d0a151f186a68bf70e4c2e310a56a07b8a`，部署作者 manifest 为 `6bf6e58373998319550d0491c4a99c366724e18a9851e66d551b24c9cb68465a`。它复用原 FollowDriver、原角色和镜头，以连续输入经过门触发，不用 `set_inside()` 代替。仅各路线起点放置一次，过程中无传送。

解析 0.937 秒；同一两图路线分别在 Vulkan 进行 receiver 与 baseline 对照，wrapper 291.750 / 186.437 秒，均退出 0、错误/警告空。wrapper 含加载和初始化，不用其总秒数换算帧率。receiver、baseline 两份独立审核与修订配对终稿通过，十八项正反测试通过；完整封存分别为三十、二十三文件。下面只列每段路线实际墙钟与模拟时间。

| 路线 | 模拟时间（两运行相同） | baseline 墙钟 | receiver 墙钟 |
|---|---:|---:|---:|
| 无名岛房屋往返 | 9.983333 秒 | 14.496570 秒 | 51.233074 秒 |
| 游仙村房屋往返 | 9.583333 秒 | 14.692523 秒 | 36.128986 秒 |

本次整段墙钟比值为 3.534151 / 2.459005。相邻 post-draw 间隔 p95（线性分位）分别由 baseline 的 0.295940 / 0.353200 秒增至 receiver 的 2.145066 / 1.363260 秒；最大间隔为 9.359847 / 6.859311 秒。每模式仅一次顺序仪器运行，其他用户 Godot 窗口未关闭，缓存及系统负载未受控，不是独立 GPU 计时或生产 benchmark。

两图均实际进入再退出，支撑缺失及低于支撑计数为 0；receiver 运行保存 83 份 ACK，停止恢复分别为 165 caster+28 receiver、208 caster+2 receiver，并确认 closed。无名岛观察到 62 个 active draw、13 个 fallback draw；游仙为 66/7。退回原太阳避免继续使用失效的旧组，但不能把退回仅四个 draw 描述成快速恢复：从首个 fallback pre_draw 样本到后续首个 active pre_draw 样本的最长墙钟跨度为 14.467410 / 8.396972 秒。此跨度包含阻塞和稀疏帧，不证明每个时刻连续显示状态，也不是 GPU 逐片元绑定时刻。

配对工具首稿增加了没有来源依据的「逐 physics 位置差 ≤0.1mm」条件，游仙最大 3D 残差为 0.14219045mm，故首稿失败保留。修订稿不把运行时浮点轨迹当逐位相等条件，而逐项核同一源码/路线定义、599/575 physics tick、模拟时间及进出 tick，并原样报告残差：无名逐 tick 位置 exact；游仙最大水平 0.01907349mm、竖向 0.14090538mm。没有修改原支撑、ACK、时钟、发布或体积数值门槛，不将旧失败改写为通过。

即使路线和清理检查通过，本次延迟也不适合实际游玩。该配对带诊断观察开销且没有孤立每项 CPU/GPU 成本，post-draw 间隔包含主/渲染线程、Shader 安装恢复、调度、CPU 校验和文件输出，不能把全部差值直接归因某个 kernel。baseline 没有 TLV producer/receiver，其通用审核的 fallback 计数仅表示未启用 TLV，不是 baseline 失效或执行了 receiver 回退。开启后墙钟大幅增长、切换期间长期退回原太阳已经是明确问题。默认继续关闭，下一步单独定位双探针绘制/阴影、材质检查、计算与读回、房屋失效及重新绑定的成本，再决定优化；不以降低原效果、放宽数值门槛或将年龄改大来宣称复原成功。

## V4 有限计数优化：新 pair 与两图路线

V4 已部署两个计算 Shader，将逐体素全局 atomic 统计改为 workgroup 归约，保留所有计数、有限值检查、浮点公式及纹理写入；filter、cull、更新频率与其余十二份 V3 源码保持。逐 pair 约 1,048,576 次向少量全局地址累计是源码发现的热点候选，没有因此确诊全部瓶颈。

V4 独立静审十七项正反检查与重跑作者二十三项 fixture 通过。全有效双 cascade 的全局状态 atomic 从 1,048,576 次降为 16,384 次，但 shared atomic 仍为 1,048,576 次，并增加组内 barrier；不能换算成六十四倍提速。两个 Shader 的提前 return 留在 voxel helper，所有 invocation 无条件经过两道 main barrier；逆变换核对保留原浮点、有限校验和纹理读写。独立审核器首稿漏去一个新增空行而导致字符串比较失败，原工具与诊断另存，v2 修订审核器后通过；不是修改 Shader 来消除该失败。

新 `realtime-pair-vulkan-v4` wrapper 61.531 秒，退出 0、错误/警告空。actual snapshot 1、双 callback frame 42 保存十四份完整取样；八项 raw/isolated 原门槛均 ≤1 adjacent binary16 ULP，最大 1、超过 1 的分量 0；四项端到端最大 3 仍独列。十三项独立正反测试与二十四项作者 oracle fixture 通过。十一完整 ACK 为八 accepted、两 house 状态取消、一最终退休；恢复 165 caster、remaining 0、错误空、closed，receiver=false/published=0。此 pair 的 house 仍是 `set_inside()`，不能与下面的真实路线混称。完整读回的 61.531 秒不能视作正常实时性能，也不要求它与先前 D3D12 图像或 UBO 相同。

随后单无名岛 `realtime-house-route-vulkan-v4` wrapper 74.329 秒，退出 0、错误/警告空，十七项独立正反测试通过。路线定义、599 physics tick、9.983333 模拟秒、enter/exit tick 150/391、全部足点与 V3/baseline 一致；一次起点放置后连续原输入，支撑缺失/下穿 0。76 route draw 中 active 66、fallback 10；43 完整 ACK 为 38 accepted、4 rejected、1 退休；165 caster、28 receiver 恢复且 closed。

| 无名岛同路线单次观测 | V4 | 原 V3 | baseline |
|---|---:|---:|---:|
| 路线墙钟秒 | 22.972856 | 51.233074 | 14.496570 |
| post-draw 间隔中位秒 | 0.140082 | 0.315640 | 0.182546 |
| post-draw 间隔 p95 秒 | 0.941647 | 2.145066 | 0.295940 |
| post-draw 间隔最大秒 | 3.844976 | 9.359847 | 0.321391 |

无名岛单次总墙钟相对 V3 降 55.1601%，仍为 baseline 的 1.58471 倍；中位间隔较低不能替代总量和尾部停顿。两段 fallback 各五个 draw，首 fallback pre_draw 至下一 active pre_draw 的跨度为 6.800277 / 6.938066 秒。

游仙村随后单独补跑 `realtime-house-youxian-vulkan-v4`，wrapper 79.796 秒，退出 0、错误/警告空，十七项独立正反测试通过。575 physics tick、9.583333 模拟秒、enter/exit tick 150/368、支撑缺失/下穿 0；一次有支撑的起点放置后经过原 house 触发，无中途传送。99 draw 中 active 92、fallback 7；54 完整 ACK 为 50 accepted、3 rejected、1 退休。208 caster、2 receiver 恢复，remaining 0、错误空、closed；两图 V4 合计九十七份完整 ACK。

| 游仙村同路线单次观测 | V4 | 原 V3 | baseline |
|---|---:|---:|---:|
| 路线墙钟秒 | 15.790978 | 36.128986 | 14.692523 |
| post-draw 间隔中位秒 | 0.096109 | 0.252875 | 0.128794 |
| post-draw 间隔 p95 秒 | 0.223305 | 1.363260 | 0.353200 |
| post-draw 间隔最大秒 | 2.722632 | 6.859311 | 0.378874 |

游仙单次总墙钟相对 V3 降 56.2928%，仍为 baseline 的 1.074763 倍；与 baseline 足点逐项一致，与 V3 最大三维残差仍为 0.14219045mm，不将三次轨迹称为 bitwise 相同。两段 fallback 样本跨度为 3.327604 / 1.273789 秒，最长四 draw。两图都有明显门口停顿，部分中位/p95 降低不足以认定流畅性通过。

保留 V4 的两份 Shader，默认 receiver 继续关闭。两份实际部署哈希另与封存候选核对，因为路线运行的十二项 source snapshot 本身不包含它们，不能仅凭该 snapshot 推断 Shader 未变。缓存、系统及其他用户 Godot 窗口负载没有隔离，间隔仍含 CPU、Shader 安装恢复、提交等待及日志；这些单次观测支持保留局部优化继续定位，不是隔离 GPU 计时、生产性能或流畅性通过。fallback 跨度仍是两次 pre_draw 采样间的墙钟差，不证明连续光学显示或逐片元 epoch。门口安装/恢复、双探针及其他成本须继续分项定位。

## 尚未完成与归档

实时太阳候选尚未接默认试玩；局部灯体积、原 UE 阴影等价、两图全地图连续行走和最终画面、可见阴影与风动画的时刻关系、GPU epoch 一致消费、长期运行/切地图资源行为和可接受性能均未完成。本轮只封存可审代码与阶段证据，后续性能优化独立推进，不代表完整功能、完整复原或用户美术验收。文档封存前最近远端只读核对仍为 `18b0c3b`，本轮 Git 推送尚未发生；后续实际同步结果另记，审批超时或网络读取失败不能记为已同步。

原始运行与完整捕获保留在 `workbench/reports/landscape-drift-20261127/` 下对应 sidecar、pair、receiver frozen/normal、house-route/house-baseline 及 wrapper/deployment 目录。前三项完整独立 CPU 已归档为 `realtime-sidecar-cpu-v1`、`realtime-pair-cpu-v2`、`realtime-sidecar-youxian-cpu-v2`；V2 包含 47 文件及完整差异，游仙包为 17 文件。V3 独立 25 文件归档为 `realtime-receiver-independent-cpu-v3`，作者报告和对照面板位于 `realtime-receiver-v3-results`。连续穿门与 baseline 的三十、二十三文件独审包已归档为 `realtime-house-route-independent-cpu-v1`、`realtime-house-baseline-independent-cpu-v1`。V4 新 pair 的三十六文件、无名与游仙各二十九文件独审包归档为 `realtime-pair-independent-cpu-v4`、`realtime-house-route-independent-cpu-v4`、`realtime-house-youxian-independent-cpu-v4`，保留各自版本的数值、路线和限制。具体路径/哈希由本包 evidence manifest 记录。Git 仅纳入十四个实时源码、一份穿门诊断和本篇/AGENTS 两文档；大体积 rgba16f、差异 NPZ、GPU UBO、资产、缓存和引擎不混入核心提交，归档保存另用明确清单。


## 2026-11-28：室内外切换的 CPU 计时与文本处理

本节的 CPU 计时 V1/V2/V3、CPU 文本优化 V4 是新一轮编号，与上节两个计算 Shader 的 GPU 工作组归约 V4 不同。后者保持部署。本轮只改主线程诊断及纯文本处理，未改太阳体积公式、raw/filter 舍入、纹理写入、Shader 受光公式、模型或原镜头。没有因为本轮改动重跑完整体素数值取样，也不能将旧数值报告写成新一轮实测。默认试玩仍关闭实时 TLV receiver；新增详细计时仅由显式 `--tlv-stage-timing` 开启。

计时记录每段同步函数的单调时钟、实际 draw/physics 帧及父子关系，另记房屋失效、旧任务清空、重扫描和新组可用事件。默认不创建 recorder，不采集计时；文本优化仍在显式安装时生效；启用后只在内存保留有界记录，案例结束后统一导出。同步时间包含函数中的等待与调度，不是 CPU 核活跃时间或 GPU 硬件计时。父子 inclusive 时长、scan/bind/build/comment 聚合互相重叠，不能相加；事件之间的延迟也不能加进同步耗时。

无名岛 CPU 计时 V1 实际路线为 22.209260 秒，2747 条记录无丢弃、未结束 span 或 recorder 错误。门口两次 caster 安装合计 6.654804 秒、receiver 安装 4.505299 秒；路线内 caster_prepare 78 次合计 2.625597 秒。房屋自身状态切换很短，等待旧任务清空约 0.069/0.137 秒，较长停顿主要落在重新安装阶段。这里区分路线内和整个案例，不把初始化计入路线合计。

CPU 计时 V2 增加 builder 聚合和 `caster_verify`，wrapper 77.812 秒、实际路线 23.778219 秒、退出 0、引擎错误/警告空。caster 进/出屋安装 3.594339/3.551269 秒，其中实际 `build_candidate` 调用合计 0.979607/0.984952 秒；receiver 安装 2.512398/2.365122 秒，builder 仅 0.096942/0.085937 秒。builder 首次至末次的跨度含调用间隙，不能当 builder 总和，也不能把剩余时间全部称为 Shader 编译。首版独立适配器错误要求 caster `calls == bound`，失败包保留；修订版按已有控制流核对：Ambient fixed-Y=false 在 builder 调用后才跳过，所以 199/205 次构建与 165 个绑定并不矛盾。原候选与原始记录未为该失败修改。

CPU 计时 V3 继续单独测量扫描、绑定及注释遮罩，wrapper 97.031 秒、路线 39.472655 秒、退出 0、错误/警告空。该次多个阶段同时变慢，系统负载和调度未隔离，不能把跨次差值确定归因新增计时。进/出屋注释处理占 caster 安装的 47.01%/47.69%，占 receiver 安装的 70.46%/77.69%；原实现对每条注释逐字符追加空格并反复重建整段源码，是已测得的主线程热点之一。扫描包含构建、构建又包含部分注释处理，只可从 scan 减去明确的 in-scan comments，余量仍不能称为编译时间。

CPU 文本 V4 把注释遮罩改为同一正则匹配、按 LF 保留空段、原生重复空格及一次分段拼接。Unicode 字符位置、LF、CR 处理和旧正则对引号/未闭合注释的行为保持；它不是新解析器，也不缓存修改中的材质状态。另一项优化在一次同步 `verify_bound_state` 内按 Shader 实例 ID 复用 SHA，函数返回即释放；下一次检查重新读取当前代码。原材质身份短路、原/新 Shader 哈希、next_pass、render_priority 和四个自有相机 uniform 检查及错误顺序保留。

注释等价测试覆盖 203 个实际/合成输入，最终引擎 stdout 为 1147 项通过；JSON 为 1146，因为 JSON 对象在额外的输出文件打开检查之前构造。首稿测试缺少显式 return 的解析失败及修订记录保留。扫描 fixture 首稿在 SceneTree 初始化阶段取节点路径产生错误，修订为 deferred 后 1.859 秒、59 项通过、错误/警告空；不能只用原进程退出 0 覆盖旧错误。SHA memo 独立测试 0.860 秒、61 项通过、退出 0、错误/警告空，验证逐调用重读、共享/同码不同资源、所有权与参数失败及错误顺序。

CPU 文本 V4 的无名岛实际结果显示局部工作减少：`caster_verify` 中位从计时 V2 的 35.992 ms 降至 4.284 ms，进/出屋注释处理为 0.343903/0.371174 秒，receiver 安装为 1.426694/1.419483 秒。但 caster 安装仍为 4.470466/4.617655 秒，整段路线 33.597777 秒，高于 V1/V2 约 22–24 秒。保留这个真实结果，不把局部改善写成整段加速或流畅性通过；这些仍是顺序运行、未隔离系统负载的带诊断观测。

无名 CPU 文本 V4 实测独审包为 `house-cpu-text-wuming-audit-v4-20261128`，manifest `4e50c31aa4db989c0e619189825ff53a6b6d3a24058a6f04f14b18088dc85625`。165 个 caster 的完整报告逐项核对 source/bound/template 哈希、fragment/inverse 标记及替换数一致。receiver 原始记录没有完整逐材质 inventory，不能把 caster 的检查扩展成 receiver 跨次运行逐 Shader 哈希核对。

游仙村 CPU 文本 V4 路线 25.215411 秒，较旧 GPU 工作组 V4 的 15.790978 秒更慢；最大 post-draw 间隔 3.797089 秒，旧值 2.722632 秒。caster 进/出安装 2.519461/2.953898 秒、receiver 0.636667/0.610126 秒，verify 中位 5.511 ms。575 physics tick 保持，足点相对旧 GPU V4 最大三维差 0.14219045 mm，不能称 exact。实际 caster 各代绑定数 208→205→208；首审核误写必须各代同数，失败保留，修订按各代真实记录核对。最终 208 caster 报告标签及哈希一致，42 完整 ACK、208 caster+2 receiver 恢复和 closed 通过。修订独审为 `house-cpu-text-youxian-audit-v4-corrected-20261128`；不能用通过代替流畅性结论。

CPU 分析 V5 在单次同步 caster install 内复用纯文本结果：注释/可达顶点风险以完整输入 String 为键，builder 以 family、实际 `_template_cache` 文本及源码为键。模板第一次读取仍由原函数完成；模板槽改变或移除按新输入计算，未知 family 和失败结果不缓存，成功 Dictionary 在存入与命中返回时分别深拷贝。install 返回前清空，不跨 install、帧或资源生命周期复用；原遍历、参数读取、Shader 创建、所有权验证与恢复保持。244 项真实引擎测试及 110 项独立源码/证据检查通过；nested 失败用例只证明外层 memo 不被清空，不证明嵌套计时归属。V5 的 build/comment 计时改为逻辑 wrapper（含命中、查找/复制和 miss），不得继续称为纯 super 执行时间。

CPU 分析 V5 随后实际跑完两图，wrapper 218.609 秒、退出 0、错误/警告空。下面均为路线内观测，不含整段加载时间；V4 指本节的 CPU 文本 V4。

| 地图 | V4→V5 路线墙钟秒 | V5 caster 进/出安装秒 | V5 receiver 进/出安装秒 | V5 最大 post-draw 间隔秒 | V5 失效→新组可用秒 |
|---|---:|---:|---:|---:|---:|
| 无名岛 | 33.597777→28.320491 | 1.146753 / 1.364717 | 1.463586 / 1.463770 | 2.233761 | 4.284907 / 4.205785 |
| 游仙村 | 25.215411→19.626735 | 1.100708 / 1.149747 | 0.604260 / 0.633151 | 2.066088 | 3.415195 / 4.335282 |

两图各代 builder 实际 miss 降为 5/6 次，comments 为 27/22 次，risk 为 13/6 次；所有材质仍逐项遍历、读取参数并执行原绑定/校验。V5 verify 中位为 4.409/5.791 ms。两图相对各自 CPU 文本 V4 的足点、phase/state、599/575 tick 与模拟时间 exact。无名 42 完整 ACK（37 accepted、4 rejected、1 retired），恢复 165 caster+28 receiver；游仙 41 完整 ACK（36、4、1），恢复 208 caster+2 receiver；两图 closed。同步记录无丢弃、未结束 span 或 recorder 错误。

无名 165 caster 完整标签逐项一致；游仙 134 项原始路径身份一致，74 项仅自动节点名数字后缀变化，按记录中的明确映射后 208 行一致，其余标签去 nodes 后的完整多重集一致。原始路径严格比较失败仍保留，不能称游仙 raw identity exact 或 GPU 实例归属已证明。此次路线低于各自 CPU 文本 V4，但仍高于旧 GPU 工作组 V4 的 22.972856/15.790978 秒；不同运行的系统负载未隔离，不能据此计算稳定提速率。门口仍有约 2 秒单次绘制间隔和约 3–4 秒失效至新组延迟，默认继续关闭；保留局部优化继续定位，未通过完整流畅性或画面验收。

阶段证据按实际 V1、V2 修订、V3、CPU 文本 V4 两图与 CPU 分析 V5 双图分别保留；旧测试/审核失败不回写。原始 JSONL、ACK、运行日志留在本地 `workbench/reports/landscape-drift-20261127/`，独审与小测试拟集中归档 `cpu-timing-and-text-20261128/`；该归档动作和 Git 提交/推送须以实际执行结果为准，本文不预先记为已同步。Git 只取核心源码和小文档。本轮仍不证明原版 UE 完整等价、两图全地图画面、长期资源行为、GPU 逐片元 epoch 一致消费或美术验收。


## 2026-11-28：房屋绑定复用 V6 / V7 与实际命中

V6 新增保守的同集合复用：仅房屋状态失效可尝试；通用 owner 失效或两类合并仍完整重装。先检查 receiver 的归属、完整材质集合和库源码，提供原 Shader 视图；再重新核对 caster 的可见性、layers、shadow、fixed-Y、完整源码与模板、材质身份及引用图。集合、归属或图发生实际变化时保留 receiver.restore→释放→caster.restore→install 顺序。复用期间 receiver 保持 mode 0，只有当前 generation 的新鲜双级 pair 才恢复接收，不复用旧体积，也未改 age 8、ACK、数值门槛或 Shader 公式。

V6 两图实际路线 wrapper 104.625 秒、exit 0、errors/warnings 空，但四次房屋转换全部回退，没有任何复用命中。其路线虽比 V5 短，不能归因为复用优化。后续只增加有界图差异诊断；单无名运行发现进/出屋 71/65 项差异，全部是 shadow OFF 的原粒子 visible_instance_count 随模拟变化。3701 个几何实例及其材质关系保持，不能将这个计数当成静态引用关系变化。

V7 仅允许已验证身份的原粒子忽略该实时计数：从实际 original_particles.gd driver 的 _emitters 获取 draw/multi 关系，检查脚本、_generated/_world 父节点、source/source_group 和 metadata，保存 owner/source 身份。未知实例、伪 metadata、重复归属、source 或 owner 变化、容量/mesh/材质槽/next_pass/shadow 变化仍拒绝；不跳过整张引用图，也不忽略所有 MultiMesh 的数量变化。引用图本身不校验 mesh 顶点内容，不能扩展为任意原地几何编辑的等价保证。

V7 最终干净 CPU 运行通过 30 项新用例及 60 项前版回归；独立源码逆变换与依赖审核 123 项通过。首轮虽打印 28 项通过却有 7 条 String/int 诊断比较错误，已按实际类型比较修正，旧日志原样保留，不以进程 exit 0 覆盖错误。

最终两图实际运行 `realtime-house-reuse-v7-run` 为 98.390 秒、exit 0、errors/warnings 空。独立审核沿用 142 项自测及原 route/ACK/freshness/source 合同，封存前 40 项输入稳定性检查通过。无名两次 reused，只有初装 generation [0]，两次切换中没有 restore/install 调用；游仙两次明确因 Visible caster material count changed（208→205→208）重装，generation [0,1,2]。

| 本轮单次路线观测 | 无名 V6 | 无名 V7 | 游仙 V6 | 游仙 V7 |
|---|---:|---:|---:|---:|
| 路线墙钟秒 | 13.405222 | 10.858271 | 11.793684 | 12.099668 |
| 最大 post-draw 间隔秒 | 1.144497 | 0.605975 | 0.958445 | 1.110353 |
| 进屋失效到 fresh 秒 | 2.124222 | 0.752735 | 1.425561 | 1.589363 |
| 出屋失效到 fresh 秒 | 2.331069 | 0.707447 | 1.670421 | 1.803322 |
| 进屋检查秒 | 0.125256 | 0.453031 | 0.070854 | 0.229703 |
| 出屋检查秒 | 0.125490 | 0.430353 | 0.068267 | 0.225781 |

无名 V7 检查更深入、检查本身更慢，但省掉两次 caster 和 receiver 重装；游仙仍需重装，本次总量和尾部间隔反而更长，不能称两图都改善。以上都是各版本一次带诊断运行，其他用户 Godot 工程、驱动缓存和系统负载未隔离；不是稳定提速率、引擎 FPS、GPU 硬件时间或输入延迟。无名仍有约 0.606 秒的最大绘制间隔，未通过流畅性验收。

两图相对 V6 的 phase/state/599或575 physics tick/模拟时间/足点均 exact；这不覆盖 V5→V6 游仙约 0.14219045mm 的既有差异。无名 59 完整 ACK（55 accepted/3 rejected/1 retired）、恢复 165 caster+28 receiver；游仙 92 ACK（88/3/1）、恢复 208+2；两图 closed。无名完整 165 条最终 caster label exact；游仙 74 条 nodes 自动名字后缀变化（20 SourceBird/54 SourceAmbient），其余标签去 nodes 后多重集 exact，原始差异保留，不称跨运行对象 identity 相同。receiver 无完整逐材质跨运行 inventory。

`shader_assignments: 0` 是代码声明，不作为独立运行测量；实际复用证据来自已审且 source hash 对应的无 Shader 指派路径、实际 owner/code/template/visible set 检查、没有重装事件及后续 verify/restore 无冲突。未获得逐材料 Shader 实例 ID 轨迹或逐 fragment epoch，不扩大证据范围。

本轮九个已封存包和四份 CPU 日志已按逐文件 SHA 归档，合计 150,035,069 字节（含便携视频包）；索引为 `workbench/reports/landscape-drift-20261127/house-reuse-and-video-20261128/archive-index.json`。V7 实际独审包 manifest 为 `d6a2c8645736ec6c5516cbc27ce5658f56581cf5fa1ac88f469dd9978723b42d`。失败历史未删除；原始 GPU/路线记录仍在各 run/output 目录。

两图正常速度录像另见 `docs/SCENE_COMPARISON_20261128.md`。它们采用默认 TLV 关闭场景，不是 V7 卡顿性能证据。默认 Vulkan 和 TLV 关闭保持；局部灯体积、完整 UE 后期/透明受光、全地图动态/显隐/通行、长期稳定性和美术验收仍未完成。游仙集合变化下的安全增量处理、检查成本以及实际正常行走体验仍待后续。本轮文档写入时上一已同步提交为 `2c16e6b`，新提交与推送结果以 Git 实际记录为准。
