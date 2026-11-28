# Actor 显隐与码头箱桶修复（2026-11-28）

原版观景窗口的无名岛码头没有箱桶，而 Godot 显示了这些物体，根因是导入器读取了网格组件的可见性，却漏掉所属 Actor 的 `bHidden` 和 `bActorEnableCollision`。本轮从发布版 cooked map 与原生反汇编恢复已证实的初始状态；这些资料不是开发商源代码。

## 来源与覆盖

本地只读来源为 `artifacts/wandering-full-scene-study-20261123` 中 decoded cooked JSON、placements，以及 `project/assets/{wuming,youxian}/{world,collision}.glb` 的 source extras。精确源文件 SHA 和 20 个 VisibleComponent Actor 的原始有序条件保存在 `actor-visibility-evidence-20261128.json`。未修改原游戏、存档、模型、材质或孤屿工程。

|地图|静态网格 Actor|组件|带 VisibleComponent 的 Actor|初始隐藏且禁碰撞|
|---|---:|---:|---:|---:|
|无名岛|2080|2182|20|17|
|游仙村|788|871|0|0|

这里的覆盖限于两张已导出主图中的静态网格放置 Actor，不包含全部 NPC、粒子、交互代理或剧情子关卡。一个无关 Harvest archetype 缺少 decoded 文件；17 个修复对象的 Actor flags 均是本对象显式值，不依赖该缺失模板。

## 当前观景存档为什么没有码头箱桶

隔离观景存档以早期原存档为基础，只改 MapName 与起点。两图 viewer baseline 与 runtime 文件分别逐字节一致。无名岛 SHA256 为 `9e2f84d0fa1c953ea30f3d4fc7abc1c4888e44e595dec4f93efb4a4a6ac149ea`；游仙村为 `ab98da9e1824291e09eb54fba021fe804fcf390bca027583f51a629816d4803a`。

两图 Quests 数组均有 9 条记录：5001/Finished、5000/Requested、5002/Finished、5003/Finished、5012/Requested、5004/Requested、5005/Requested、5006/Requested、5016/Finished。任务 28967 和 28968 均不存在。这是对 Quests 结构的完整解析结果，不是字符串或字节搜索推测。

`QuestSpec` 原生反射确认字段偏移：QuestId=0、Step=4、QuestProgracessData=8、RequestTime=32、FinishTime=36。原生序列化 `0x141225d90` 依次处理 int32 ID、uint8 Step、进度数组、int32 RequestTime、int32 FinishTime；当前 9 条进度数组均为空，每条序列化占 17 字节，恰好消耗 153 字节记录数据。

Shipping EXE SHA256 为 `8c3928aea470b45aff2050ffe1034306122f2ed221a43875f20ef1e61b274df8`。该版本的静态证据链为：

- `EQuestStep` 反射表 `0x1444b97b0` 明确记录 None=0、Requested=1、Faild=2、UnRequest=3、Finished=4。这里不要与 `EJumpQuestStepType` 混用。
- `CheckRequirement` 的 PreQuest 分支 `0x140f7e4b0` 调用 QuestManager 的 `GetQuestStep`（`0x141252500`，反射 thunk `0x1413702d0`），将读取的 Step 转为浮点后与 Num 相等比较。
- `GetQuestStep` 查找失败返回 None=0。因此当前两图观景存档的 PreQuest(28967,4) 与 PreQuest(28968,4) 均为 false。
- `HasQuest` 分支 `0x140f7d663` 调用 `0x141257780` 检查任务是否存在，不读取 Num。此轮相关的 32028 同样不在当前 9 条任务中。不能把 HasQuest 的 Num=4 也解释为 Finished 检查。

码头 P1、P478、P486、P487、P488、P501 共 6 个 Actor（9 个视觉节点、11 个碰撞体）都是初始隐藏/禁碰撞；两条任务完成条件中的任一满足才会显示。当前默认观景状态不满足，所以保留原初态。

## 原生 VisibleComponent 的行为

反射 `ApplySceneNPCSettings` thunk `0x1413892c0` 指向实际函数 `0x140f9fa70`。函数按 SceneNPCSettings 数组顺序检查，每项 RequirementSettings 是 AND；满足项中的动作按顺序更新最终可见值，后满足项覆盖前项。没有任何项满足时，不改变既有显隐。bTriggerOnce 已触发项会跳过；本次 20 个对象所用设置保持原有顺序。

最终动作 `0x140fc4a70` 以可见值的反值调用 Actor 的 SetActorHiddenInGame，并以可见值调用 SetActorEnableCollision（`0x142d25010`）；两者通过 UE 反射 thunk `0x143555930` / `0x1435558a0` 交叉确认。此次仅用这些证据解释初态，不在 Godot 新增任务模拟器。

## 20 个带 VisibleComponent 的 Actor

所有下列条件在当前 viewer 的 9 条任务状态下均不满足。前 17 个目标恢复初始隐藏和禁碰撞；其余 3 个初始可见对象继续可见，不能按“存在条件组件”统一隐藏。

|图/Actor导出索引|Actor|本轮初态处理|原有条件顺序|
|---|---|---|---|
|LV_WuMinDao_P / 1|`Actor_0`|隐藏/禁碰撞|PreQuest 28967 / 4 → 显示；PreQuest 28968 / 4 → 显示|
|LV_WuMinDao_P / 122|`BP_YaoYi_2`|隐藏/禁碰撞|PreQuest 32035 / 4 → 显示|
|LV_WuMinDao_P / 478|`SM_Item_daizi13_18`|隐藏/禁碰撞|PreQuest 28967 / 4 → 显示；PreQuest 28968 / 4 → 显示|
|LV_WuMinDao_P / 479|`SM_Item_gongzhuo002_139`|隐藏/禁碰撞|PreQuest 32100 / 4 → 显示；PreQuest 32102 / 4 → 隐藏|
|LV_WuMinDao_P / 486|`SM_Item_lanzi13_11`|隐藏/禁碰撞|PreQuest 28967 / 4 → 显示；PreQuest 28968 / 4 → 显示|
|LV_WuMinDao_P / 487|`SM_Item_mutong002_8`|隐藏/禁碰撞|PreQuest 28967 / 4 → 显示；PreQuest 28968 / 4 → 显示|
|LV_WuMinDao_P / 488|`SM_Item_muxiang33_2`|隐藏/禁碰撞|PreQuest 28967 / 4 → 显示；PreQuest 28968 / 4 → 显示|
|LV_WuMinDao_P / 497|`SM_Item_shineibihua002_142`|隐藏/禁碰撞|PreQuest 32100 / 4 → 显示；PreQuest 32102 / 4 → 隐藏|
|LV_WuMinDao_P / 501|`SM_NJ_HuoyaoMuxiangzi_001_5`|隐藏/禁碰撞|PreQuest 28967 / 4 → 显示；PreQuest 28968 / 4 → 显示|
|LV_WuMinDao_P / 504|`SM_xgg_yjzptong10_150`|隐藏/禁碰撞|PreQuest 32100 / 4 → 显示；PreQuest 32102 / 4 → 隐藏|
|LV_WuMinDao_P / 508|`wudang_shineiqiangbizhuzi001_145`|隐藏/禁碰撞|PreQuest 32100 / 4 → 显示；PreQuest 32102 / 4 → 隐藏|
|LV_WuMinDao_S / 4110|`SM_HD_Dashu16_5`|原可见，保留|PreQuest 32005 / 4 → 隐藏|
|LV_WuMinDao_S / 4112|`SM_HD_Huacao033_33`|隐藏/禁碰撞|HasQuest 32028 / 4 → 显示|
|LV_WuMinDao_S / 4113|`SM_HD_Huacao038_37`|隐藏/禁碰撞|HasQuest 32028 / 4 → 显示|
|LV_WuMinDao_S / 4121|`SM_HD_Huacao34`|隐藏/禁碰撞|HasQuest 32028 / 4 → 显示|
|LV_WuMinDao_S / 4223|`SM_Item_dengzi3_23`|原可见，保留|PreQuest 32005 / 4 → 隐藏|
|LV_WuMinDao_S / 4224|`SM_Item_dengzi4`|原可见，保留|PreQuest 32005 / 4 → 隐藏|
|LV_WuMinDao_S / 4729|`SM_mjsz_huapen001_29`|隐藏/禁碰撞|HasQuest 32028 / 4 → 显示|
|LV_WuMinDao_S / 4731|`SM_mjsz_huapen2`|隐藏/禁碰撞|HasQuest 32028 / 4 → 显示|
|LV_WuMinDao_S / 4736|`SM_mjsz_huapen7`|隐藏/禁碰撞|HasQuest 32028 / 4 → 显示|

## 最小实现与验证

`project/scripts/original_actor_initial_state.gd` 和可提交的 `project/scripts/data/original-actor-initial-state.json` 以 source_map 与完整 component source_name 精确匹配。`worlds.gd` 在导入实例后初始化视觉；`original_collision.gd` 在缓存和新建碰撞两条路径初始化碰撞。保留几何、shape、原组件可见值与碰撞 layer/mask，保留原始有序任务条件，供后续有证据的适配恢复使用；没有按截图删除物件，也没有增加逐帧显隐锁。

无名岛精确命中 20 个视觉节点、18 个碰撞体；19 个视觉节点新增隐藏，另 1 个组件本来不可见。17 个 Actor 均不在房屋 inside/outside 名单，反复进出房屋切换不会重新显示它们。游仙村规则数量与命中数均为 0。

- 可提交的小型 Godot headless CPU 回归（只需核心脚本和 manifest，无大资产）323 项检查、0 失败。
- 同一测试以 `--source-assets` 直接读取本地 GLB JSON 构造轻量节点：12175 项检查、0 失败；涵盖无名岛 3378 视觉/2488 碰撞节点、游仙村 1784 视觉/684 碰撞节点、真实房屋分组、多次应用、原过滤层保存及错误包名/名称前缀负例。
- 之前部署 v2 的 8985 项检查通过；新增 mask 检查后计数增加，不表示新增了更多生产改动。
- 静态二进制反射和两图原存档结构解析工具已通过。所有测试均在临时目录，未启动 GPU、原版游戏或改写存档。

命令（在仓库根目录；Godot 可用 `--godot` 指定）：

```powershell
python tools/verification/verify_actor_initial_state.py
python tools/verification/verify_actor_initial_state.py --source-assets
python tools/verification/audit_source_quest_state.py --exe 'E:/Wandering Sword/Wandering Sword/Wandering_Sword/Binaries/Win64/JH-Win64-Shipping.exe' --save 'artifacts/wandering-original-worlds-review/native/viewer-baselines/wuming/SaveGames/30.sav' 'artifacts/wandering-original-worlds-review/native/viewer-baselines/youxian/SaveGames/30.sav'
```

## 实际世界与画面对照补充

主任务随后运行 `actor-runtime-v1`：真实 Vulkan Forward+、两图正式 worlds、98.547 秒退出 0，错误/警告/超时/中断均无。独立复核实际 JSON 与无名同机位前后 PNG 的 1060 项检查全部通过。

无名运行时命中 17 个 Actor、20 个视觉节点、18 个碰撞体，19 个视觉节点新增隐藏；再次应用时视觉与碰撞 changed 均为 0。游仙仍 0 命中、0 改动。每图直接调用真实 house_driver `set_inside(true/false)` 两轮，共四次状态转换，初态保持。此项验证的是房屋状态干扰，不是人物实际穿门或真实碰撞行走。

无名前图只恢复本次保存的原组件可见/碰撞过滤状态，后图重新应用 Actor 初态；相机完全相同。码头箱桶随正确初态消失，船、栈道、角色、岸线布局保留。拍摄期间水与植被时钟继续运行，因此这组前后图不是锁相位逐像素等价检查。运行报告 SHA256 `3d210cc71f7f22195f1c6e265f631f55613b53353af8545dd07874253a007caa`，完整记录在主任务 `actor-visual-light-20261128/actor-runtime-v1` 和 `actor-runtime-independent-review-v1`。

显隐改变后，主任务刷新无名派生 scene capture 和 SH9，并保留旧缓存。游仙 capture-v2 恢复后主画面仍有 25 个通道最大差 1，严格恢复失败记录保持，未因此刷新游仙缓存；不能将无名单图通过写成两图 capture 全通过。

另对主任务 `light-ab-v1` 做独立 CPU 解码核验：GPU 154.656 秒退出 0，报告 failures 为空；两图四机位 baseline-repeat 与 restored 均逐字节一致。无名 434 个 ShaderMaterial/323 个 SH9 材质、游仙 301/275 的运行时恢复计数一致，errors 为空、state_restored=true；独立 109 项通过。首审误加 alpha 通道，均值分母与源 RGB8 不同，错误报告保留；修订按 PNG 原生 RGB8 重算，未改图像或门槛。全图 changed-channel 统计不是水体 ROI，也不是美术优劣指标；本独审未修改 Film 或 renderer。

CPU 与实际世界验证均不能代替完整原版场景对齐、任务迁移、真实连续行走、正常性能或美术验收；完整剧情状态迁移、其他对象类别与全部环境复原仍未完成。
