# 画面复原进度（2026-11-28）

本轮从原版证据修复无名岛码头箱桶等物件的显隐，补充原源参数驱动的 Vignette（暗角），并将水面偏亮青蓝拆成光照贡献逐项检查。所有工作在独立 `F:/逸剑godot`，没有改动正式孤屿工程。来源是发行版 cooked map、编译 Shader、原生反汇编及隔离观景存档，不是开发商工程源码；完整复原尚未完成。

## 已完成的显隐修复

导入器原来只保留网格组件可见性，漏掉 Actor 的 `bHidden` 与 `bActorEnableCollision`。本轮恢复无名岛 17 Actor 的初态，对应 20 视觉节点、18 碰撞体，19 个视觉节点新增隐藏；另外 1 个原本已经不可见。游仙村没有同类初态目标，保持 0 改动。几何、物理 shape、原组件可见值和碰撞 layer/mask 均保留。

当前两图 viewer 存档都只有 9 条早期任务，没有码头物件的显示条件任务 28967/28968。原生 `GetQuestStep` 缺任务返回 None=0；PreQuest 的 Num=4 对应 `EQuestStep::Finished`，两个条件均不成立。20 个带 VisibleComponent 的 Actor 已核对：17 个恢复初始隐藏，其余 3 个原可见对象保持；没有新增剧情任务系统。

实际 Vulkan Forward+ 的 `actor-runtime-v1` 运行 98.547 秒退出 0，独立 1060 项检查通过。同机位前后图可见箱桶随正确初态消失，船、栈道与岸线布局保留。每图直接调用真实 house_driver 四次室内外状态切换，目标保持；这不是人物实际穿门。拍摄时水和植被继续动画，不能称锁相位逐像素比较。核心 CPU 回归默认 323 项、全本地 source 节点回归 12175 项通过，详见 `ACTOR_VISIBILITY_PROGRESS_20261128.md`。

## 暗角来源、默认接入及未通过的运行验证

源两图主 PostProcess 记录启用 `VignetteIntensity≈0.65`。原生基类/JH 构造函数确认缺省 `bEnabled=true` 和 `BlendWeight=1`；原入屋 BP 不改 Vignette，出屋恢复完整 Settings 缓存。所选单个启用、unbound、全权重且 override 明确的记录才接入；不支持的记录返回强度 0 并报告原因，不猜测多体积混合。

源编译 Tonemap VS/PS 支持居中单视口的 VignetteSpace 与 `1/(1+dot(v,v))²` 遮罩，放在 Bloom 后、原 Film 前。16B push 常量的 offset12 复用为强度，0 时跳过遮罩；原 Film 函数、两个 1072B 参数文件及资源释放路径保持。包中存在该编译操作不等于已采到原游戏某一帧最终 permutation/CB；偏心、立体、裁切 lens mapping 不在本候选范围。

冻结 `light-ab-v1` 运行 154.656 秒退出 0，两图四机位 baseline-repeat 与 restored PNG 字节一致。两图 434/301 个 ShaderMaterial 的运行时恢复无错误；独立 109 项检查通过。首审将原 RGB8 误转 RGBA，导致均值分母不符；首稿保留，修订按原生 RGB8 重算，未改图像或阈值。分项 A/B 证明可恢复和存在贡献，不等于默认接入后运行验收。

默认接入后的两轮 Vulkan 测试均未通过，不能写成默认 GPU 成功：

|运行|实际结果|边界|
|---|---|---|
|default-vignette-run-v1|无名已输出室外→室内→室外→室内→室外 5 个状态，强度均约 .65、time_scale=1；随后游仙首次绘制 Vulkan device lost。wrapper 315.312 秒超时，退出值 null，sandbox `taskkill` Access denied，原记录 owned_process_stopped=false。主任务提权后仅终止本任务 PID28700 与 child8264。|无名片段不能代表两图整轮通过。旧失败及清理失败日志保留。|
|default-vignette-run-v2|正常 desktop 提权、同一验证脚本复测，AMD Radeon 780M / Vulkan Forward+；无名首次载入即 device lost，wrapper 最终退出 1、180.391 秒。日志栈为 original_footsteps.select_map→place_at_source_actor_position→worlds 第168行，此时尚未调用 renderer.setup/Film 初始化。主任务仅终止 owned PID8260。|失败发生在本轮 Film 初始化之前，不是图间重复 shutdown；尚不能确诊驱动/硬件/引擎根因或宣称默认稳定。|
|default-vignette-d3d12-run-v3|D3D12 main command queue 初始化失败，日志记录两条 ERROR 和一条回落 Vulkan 的 WARNING；随后持续 AMD TDR，主任务仅结束本任务 console PID34700 与 child9552。wrapper 退出 1、211.625 秒；未进入地图、没有截图。|D3D12 未成功运行新功能，也未完成 Vulkan 回落后的地图验证。默认仍为 Vulkan，不将本轮诊断当作 D3D12 功能或稳定性通过。|

上述三轮失败记录均保留。GPU 测试已停止，本轮不再录制新视频；正常速度下两图默认状态、重载及完整往返验证待下次启动完成。日志能定位失败阶段，尚不能独立确诊 AMD 驱动、硬件或引擎的最终根因。

v1 invocation 还有重复传入可执行文件和 `--path` 的包装器调用错误，原记录保留；v2 已修正这些参数但仍失败，不能把 v1 调用错误当作 device lost 根因。Windows WER 记录截至 2026-11-28 07:43:44（Asia/Shanghai），18 条队列/归档事件按 ReportId 去重为 9 份 AMD `LiveKernelEvent 141`，桶为 `LKD_0x141_Tdr:6_IMAGE_amdkmdag.sys`。最早 WER 时间 06:46:32 早于默认暗角 v1；其后 06:54 Actor、06:57 light A/B、07:15 sky-compare 仍成功，不能据此断言 GPU 从首个事件起永久失效。时间是 WER 事件时间，不冒充精确挂起时刻；未读取 dump，仍不足以归因到某个 Shader、应用或硬件。

当前核心独立检查没有发现需修复的实际代码问题：真实两图 metadata 与 124 个正反/边界用例通过，19 项静审通过；push 布局 0/4/8/12、unsupported=0、初始 Actor 精确匹配及清理核对通过。这些 CPU 结果不覆盖上述 GPU 失败。

## 场景缓存与水体、TLV缺口

显隐改变后，无名场景 cube/SH9 已按原 capture 规则刷新，旧缓存和部署哈希保留。游仙 capture-v2 的恢复主图仍有 25 个通道变化、最大差 1，严格恢复失败保持；没有部署游仙新缓存。不能将无名单图通过写成两图 capture 全通过。

太阳、天空漫反射、反射、高度雾/大气、Vignette 已分别做可恢复 A/B。早期整幅图像统计与后续实际显示水域 ROI 分开记录；无名 water-center 机位被遮挡，已从水域判断中剔除。正确水域 ROI 中，约 .65 的 Vignette 使无名左下近水显示 Y 降低 83.88、船右降低 2.02；游仙中央降低 0.81、左侧高亮水降低 26.87、右下水降低 36.08。这里 Y 是 0–255 显示编码亮度，不是 HDR 能量或能量百分比。结果支持边缘影响较强，中心水体偏亮仍未解决；各后处理差值不能相加解释成独立能量贡献，也不能拿“变化最多”当作正确修复方向。完整来源和范围见 `SOURCE_VIGNETTE_PROGRESS_20261128.md`。

Ocean 原透明直射链涉及 ambient TLV，当前默认适配仍有 NdotL/PI 差异；Water 近水 metallic≈1/roughness0 时反射贡献不能只靠 TLV 改善。原 UE 反射 BRDF、Godot DFG/能量补偿、卷积与采样仍不等价，当前 cube 来自重建场景。不得用统一压暗、删光照层、任意 .25 常量或整体去饱和掩盖这些差异。

实时太阳 TLV 候选已有专项数值及房屋切换证据，但完整局部灯、原阴影/透明受光、正常实时性能仍未完成，默认 TLV 继续关闭。水体 BRDF、完整任务状态、全图原版画面等价、镜头舒适性与美术验收均有剩余工作。

## 归档与提交边界

本轮四个完整证据目录、四个验证/录制工具及归档工具已复制到 `workbench/reports/visual-restoration-20261128/`。所有原始文件和失败记录保留。静态对照页为 `artifacts/visual-restoration-20261128/index.html`，包含五组 Godot 前后对照；页面明确标注本轮没有新的正常速度录像，上一轮九段录像有单独入口。

归档逐文件复核 SHA256，共 426 个文件、94464101 字节。完整索引为归档根 `archive-index.json`，索引哈希 `01e44246b0af4edd797b137e409d9b1c4effc22398cdf6ec9f6b9174c48682b5`；复制结果见 `archive-result.json`。归档后仅做只读链接检查，不改写已封存证据。

核心 Git 只纳入本轮必要代码、初态数据、说明、小型测试和已有的无名派生缓存更新。本地截图、日志、录像与完整分析不进 Git，38 个既存未跟踪 UID 保持原样。提交与推送以 Git 历史和远端实际结果为准。

下一次启动先复测默认 Vulkan 的两图载入、室内外状态和重载；GPU 稳定后补正常速度行走/停留/回头录像，再继续核对中心水面反射 BRDF、透明受光与其余复原缺口。不要把本轮部分验证、静态对照或核心代码提交记为完整复原和美术验收。
