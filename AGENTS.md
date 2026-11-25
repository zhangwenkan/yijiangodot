# 逸剑 Godot 独立复原工程

用户于 2026-11-26 要求与《孤屿霜尘》完全分离。本目录是后续复原、分析、测试与资产维护的唯一工作根。

- Godot 项目：`F:/逸剑godot/project/project.godot`。
- 同版本引擎：`tools/godot/`；统一启动器：`tools/launch_godot_world.ps1`。
- 当前工作资料：`workbench/`；发布及历史证据：`artifacts/`。`workbench/gpu` 只联接本目录内的工作报告，不指向孤岛。
- 禁止把产物、截图、日志、备份或新脚本写回 `F:/孤屿霜尘/Isle-Frostdust`。正式孤岛及保留的旧组合图不属于本工程的运行依赖。
- 原版发行版仍在 `E:/Wandering Sword/Wandering Sword`；原版入口仅作对照。Godot 试玩不需要运行原版 EXE。
- 迁移不代表完整复原已完成，也不是用户对美术或性能的验收；继续保留已知缺口与失败记录。
- 可见模型、UV、法线、切线或细分的制作仍必须通过 Blender MCP 操作 Blender。Godot 负责导入、装配、材质、灯光、镜头、动画与逻辑。
- 历史 JSON、日志和截图保留原始路径与哈希。需要使用历史输入时按迁移映射定位；不得把旧记录中的路径直接作为写入目标。
- 已封存的单次部署脚本不要重新执行，尤其不能把历史候选覆盖到 `project/`。以当前生产代码及完整复原记录的有效证据为准。

## 当前复原状态与约束（从原工程迁入）


记录文件及日志名称保留主机生成的时间，不据此改写用户可见日期。完整实施、失败历史、数值证据与待办统一见 `artifacts/wandering-godot-play-review/complete-restoration/`；本节只保留后续工作必须遵守的当前事实。

- 用户要求先完整复原原版无名岛、游仙村，再由原图的实际优点决定孤岛方向。独立工程为 `project/`。旧组合场景的空间不合理、可走入海、镜头不适和画面粗糙等反馈仍须保留，不回头擅自修旧组合或替换正式孤岛。用户只认可混合方向有突破，尚未接受完整视觉效果。
- 来源是用户安装版的 cooked PAK、编译 DXBC、冻结参数和原生 EXE，不是开发工程源码。当前导入501种模型、63613个摆放、无名70/游仙40个地形组件，保留原UV与碰撞。静态源可见primitive实例材质路由已无通用未处理fallback，但这种覆盖统计不能证明动态、光照、剧情或每个像素已与原版一致。
- 新建、修改或补全可见几何，含地形、竹林、岩石、建筑、桥、UV、法线、切线和细分，继续必须经 Blender MCP 操作 Blender，再导入Godot。不得用GDScript或其他脚本造几何绕过约定。Godot只负责资产装配、材质、Shader、灯光、镜头、动画和逻辑；MCP未连接时先处理连接，不能擅自换制作路线。
- 当前默认统一渲染已包含原modern Film、标准Bloom、太阳室外30/π与室内3/π、原局部灯单位/聚光锥/LightFunction、两层解析高度雾、AtmosphericFog LUT、SH9、原材质路径及FXAA。`-LegacyLighting`仅保留旧光照诊断，不是整套旧版本。原后期执行细节、BRDF、阴影与LightShaftMask仍有差异，不凭整体降亮度或额外补光掩盖。
- 原FLinearColor以Vector4保持源值，避免重复sRGB解码；海水排序已恢复默认0。SH9为未染色E/π，原天空颜色及1.1强度只乘一次。当前AtmosphericFog透射T=1由该图原参数和饱和运算所得，RGB散射仍有效，不得因观感猜测而任意压暗透射。现场HDR天空来源是重建场景，不是原引擎GPU采样。
- 透明天空现已默认以SH9替换IRRADIANCE，绑定无名27/游仙2个材质，保留原vertex、fragment和light逻辑；室内开关随原房屋状态联动。它只修天空漫反射，不替代直接光。不要叠加第二份ambient，也不要因为未加自定义light而将已恢复的天空项删掉或重复增益。
- 两图Water各1面恢复原roughness=0，原distortion加入共享RGBA8累积与单次apply，几何和主材质参数保持；不再同时启用第二次屏幕差分折射。RainScale=0时原异常隐式normal采样仍未证实，不能因为RainNormalPower=0便把法线Z直接当1，也不能填任意常量、UV0或epsilon冒称等价。完整透明排序和原切线仍有限制。
- 真正TLV仍缺近远两级体积、灯注入、阴影、LightFunction及滤波。25个受光烟/水花的原直接光也是TLV，当前Godot Lambert仍为适配；禁止套opaque的LF/cone light()并称修复原受光。公开Compositor缺完整shadow数据，不可拿camera depth或无阴影常量体积充数。Ocean L0专项只是贡献诊断，未默认启用，不是完整TLV替代。
- 默认反射按原捕获规则使用128²六面RGBA16F场景cube、原gain一次、下半球黑色，保留可见天空并停用1个错误适配probe；probe须在renderer.setup前创建，屋内反射关闭。cube来自重建场景且早于最新材质增量，Godot QUALITY卷积/BRDF非原UE逐像素等价。已审的111/26个非SH余项全unshaded，不为假想漫反射倍增再次压低环境能量；所有受光材质的specular仍可能变化。
- 景深当前为HDR DOF→Bloom→Film，固定室外32.2m/.08、室内14.7m/.4，按真实缓冲宽度计算原CoC；仍缺完整UE Diaphragm、SeparateTranslucency，gather上限32px。镜头保持原方向和40°水平视场，不添加周期晃动。固定角度或停留稳定不代表行走高度舒适性已解决；前景FXAA相位0和原五值裁切须保留，不擅删原遮罩。
- 原瀑布两面、4处缸桶水面、游仙20只惊鸟及1组落叶材质已恢复。bagua实际是缸桶水；没有进入编译shader的实例细分/位移参数不强行补入。瀑布每面335顶点/598三角形，Godot导入已生成完整切线，原TX与运行切线平均角差.382755°、最大2.020010°；不能再称运行缺切线或据此解释整体粗糙。源PN自适应细分及完整TLV仍缺，Blender切线候选未执行。落叶独立透光阴影与完整BRDF亦未等价。
- 原Detour导航与动物树已接入；2026-11-26按原生MoveTo默认AllowPartialPath增设显式route_allow_partial，保留原目标、可达末端与target_reached=false，原route仍完整路径专用。生产20旧失败样本partial、100完整路径不变；真实猴子20次逐条回放均完成，未跨断区。游仙生产60秒36/36移动、4次partial均结束、path/surface失败0，但4次原支撑检查拒绝仍保留。此前首轮600秒超时无最终JSON、原因未定位，另一次诊断60秒通过但partial0，不能丢弃失败或声称历史83次全解决。原三维Actor逃离方向、Navigable随机查询、胶囊运动及随机序列仍有差异；不得扩大导航或补造源缺动作。
- 全图通行与海岸禁行尚未验完。2026-11-26连续输入已走通无名码头→演武场西侧原陆路、两主屋及游仙鸟院；两主屋生产往返68.69/43.91m、各2次室内外转换通过。游仙门口曾穿地19.5cm，逐调用确认平地重试多做20cm下扫且漏碰，已改为只收回自身1.2cm抬升，普通step/slide/snap保留；码头四向/台阶上下6项通过。演武场首轮稀疏路线逆序在岸边受阻，旧新控制器同样如此且该段未调用平地补偿；改为跟踪实际去程后完整306.18m往返通过，未删墙/放宽海域。18岸线样本均有碰撞/边缘阻止，其中6所选源墙、8边缘检查、4其他原墙；仅此范围，非全岸线或镜头舒适性验收。
- 主图IntoHouseTrigger6的物体/碰撞、人物.6缩放、室内外3/6m/s与灯光/Film/SH/雾/反射联动已接入；主图屋内Bloom仍为5，不能套独立游仙S5的.5。完整任务显示门控、无名27同伴和4交互代理尚未完成，未查明条件前不全放出。剧情子地图、特定任务状态和所选主图环境须分别核对，不能混装成同一状态。
- 所选两图是原晴天变体，雨参数0，未找到该场景自动昼夜天气控制器；其他剧情有雨对象，不擅自加进当前地图，也不推断原游戏没有天气。船、风、蝴蝶、惊鸟、火烟、水花、环境音等已接入部分原时序，但完整Cascade模拟、随机序列、全部触发阶段和SoundCue混音仍需原实机对照。材质与帧图绑定通过不等于全部微动态行为验收。
- 历史combined-v4完成无名→游仙→无名，动物30/36/30、Water/透明sky/反射与局部进出屋通过；27/27透明材质恢复原shader，26个应用纹理释放。7个Texture RID告警现已用不含游戏资产的最小测试定位到引擎ReflectionAtlas：同World多次capture仍7，3独立可见World为21，隐藏probe为0且节点弱引用均失效。未修引擎，不删除反射隐藏告警。原两个CMD实际窗口和真实退出通过；F7超时仍保留。历史16/17帧稀疏视频非全帧录像/FPS证据；新增改动另有各自回归，不能借历史哈希替新补丁验收。
- 当前默认全效果与动物开启的1280×720历史港口短测无名19.0462fps/游仙27.4128fps，非全图长期流畅。粒子缓存此前撤回；本轮LightFunction空项/宽筛候选也只留stage，三位置收益方向不一且游仙冻结基线自身变化，像素失败阈值未放宽，生产shader未改。另有用户其他Godot工程运行，不能严格归因；不以关闭原效果/动物、删灯或实例换取完整复原性能结论。
- 旧组合场景、原UE安装与存档、正式孤岛继续保留。最近保留审计中旧组合93/93、原Saved26/26基线哈希一致且无缺失，Saved整树无新增；不泛化为未建基线缓存树已核对。完整测试、失败与性能历史保留在报告中，不因精简本节而删除。测试通过、文件名final、路由覆盖和相对改善均不等于一比一完成或美术验收，不得把尚未还原的部分解释为原作缺点。后续仍由用户看原图体验决定孤岛方向。

本轮主要有效证据：`README.md`、`latest-check-ledger.json`、`remaining-work.md`；`gpu/source-water-distortion-v3/`、`gpu/source-transparent-sky-v4/`、`gpu/source-reflection-house-v2/`、`gpu/source-combined-v4/`、`gpu/source-performance-default-v1/`；`reports/launcher/20261125-water-sky-reflection/launcher-validation.json`、`reports/lighting/source-combined-v4-motion.json`、`reports/performance/default-runtime-after-cache-experiment.json`及原保留审计。以上相对路径均位于完整复原记录目录；详细边界与历史失败以该目录报告为准。

2026-11-26补充证据：`docs/RESTORATION_PROGRESS_20261126.md`；本地`workbench/reports/{navigation-20261126,routes-20261126,waterfall-20261126,stability-20261126,performance/lightfunction-20261126}/`。详细范围与失败保持在各目录，不写回正式孤岛。
