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
