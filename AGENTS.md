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
- 默认运行尚缺完整TLV；显式太阳候选已实现近远两级体积、太阳阴影/LF注入与滤波，限定验证及未完成项见后文。25个受光烟/水花的默认直接光仍为Godot Lambert适配；禁止套opaque的LF/cone light()并称复原。公开Compositor缺完整shadow数据，不可拿camera depth或无阴影常量体积充数；冻结太阳候选也不等于完整实时TLV。
- 默认反射按原捕获规则使用128²六面RGBA16F场景cube、原gain一次、下半球黑色，保留可见天空并停用1个错误适配probe；probe须在renderer.setup前创建，屋内反射关闭。2026-11-26已用当前材质重新捕获并更新两图SH9/cube：六面期间冻结Shader时间、清IRRADIANCE/RADIANCE反馈，并临时关闭SH开关含叶片背光EMISSION；保留真正自发光。capture-v2重复RAW/画面/材质恢复、真实1→0→1暂停恢复、compare-v2四机位及production-house-v2状态切换/退出通过。cube仍来自重建场景，Godot QUALITY卷积/BRDF非原UE逐像素等价。已审111/26非SH余项全unshaded，不为假想漫反射倍增再次压低环境能量。
- 景深当前为HDR DOF→三个源景深后发射器的独立层→Bloom→Film，固定室外32.2m/.08、室内14.7m/.4，按真实缓冲宽度计算原CoC。独立层仅无名两火焰和游仙萤火虫；Water/Ocean/瀑布/烟/水花显式false、落叶Masked保持原阶段。仍缺完整UE Diaphragm及动态独立层分辨率/重组/alpha语义，gather上限32px。镜头保持原方向和40°水平视场，不添加周期晃动。固定角度或停留稳定不代表行走高度舒适性已解决；前景FXAA相位0和原五值裁切须保留，不擅删原遮罩。
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

2026-11-26继续推进：动物原四次支撑拒绝实际命中宝箱/木板陡面，不是射线漏地，不放宽坡度/支撑保护。生产新增原次命中诊断与初始化前可选`--source-animal-seed`；默认随机不变。两个30秒固定60Hz回归的36动物、166请求和状态完全一致，各仍有1次宝箱坡面拒绝；10次partial中9次结束、末次截止时仍moving，不记全解决。证据`workbench/reports/animal-support-20261126/`。

镜头专项`workbench/reports/camera-follow-20261126/`确认8/3适配平滑造成台阶停止后33–37cm追随（26–29px），原构造/BP默认lag关闭。去平滑候选虽消除人物漂移，同绘制时刻背景最大单帧位移10.33→16.29px，未部署；原运行时和正常速度体验仍待核。进出屋距离直接跳变有原BP依据，未新增缓动。

2026-11-26透明层落地：无名两火焰、游仙萤火虫按源默认AfterDOF独立合成，Torch→Flame同组件顺序保留。Node visible/layers及模拟不改，仅隐藏原RS实例；真实遮挡/逐发射器HDR诊断与`production-integration-v4`三访图回归通过。临时DOF enabled开关保留owner；真实失败或显式owner.restore才还原preDOF链。原v1/v2/v3覆盖失败全部保留，最终使用有界可见采样且空候选同样参与数值检查，不宣称每帧必有萤火虫。两火焰非零背景仍有已记录半精度差异，游仙重复画面少量背景变化未定因；完整UE分辨率/重组/alpha、TLV及Cascade随机序列仍缺。详情`docs/RESTORATION_PROGRESS_20261126.md`与`workbench/reports/transparency-order-20261126/`。

2026-11-26太阳TLV候选已打通真实Godot阴影/原LF→两级64³半浮点SH/滤波→六族透明材质接收，仅显式冻结诊断，默认生产未启用。`compute-v4`10组raw注入及隔离filter各≤1 half ULP；端到端累积差异另记，不声称逐位一致。`receiver-v3`10机位/20级体积数值和40卷上传回读通过，六族单目标有贡献，9机位冻结/旁路/恢复完全相同；游仙default仍有3项精确图像失败，整套未通过。室内保留3/π太阳并关闭LF/阴影，冻结测试显式同步original_lightfunctions；共享瀑布为2表面/1材质。实时双级原子更新、局部灯TLV及粒子原offset仍缺，不得将冻结快照直接接入默认行走。

时间证据更正：旧水折射/receiver诊断误将byte2832当TIME；当前5696B布局为2848×2，TIME/TAA/jitter应为2816/2820/2824/2828，2832是emissive exposure。旧TIME=1.0及仅16B切片的“实际时间已验证”撤回；原深度、CoC与独立层观察保留。两水折射GLSL的`preceding[177]`也实读曝光，已部署为`[176]`，诊断改存完整UBO并核对布局。水gpu-v1运行228.359秒、错误/警告0；两图真实TIME推进、源状态和冻结恢复通过，432B Water frame各自相同，累积变化无名94812px/192109B、游仙27112px/42521B。独立CPU的真实clock/dynamic、六组HDR有限及零区exact通过；float64/div在原bound通过，但recip仍有无名底行y719共566分量超界、内部0，因此CPU三模型综合false，不放宽或遮边。其他TIME材质也推进，不以累积变化单独证明水原生等价；本次游仙restore通过不取消历史漂移。

游仙漂移最新定位：stage-v2的66/66对最早在POST_OPAQUE变化，完整UBO/深度/折射累积相同，真实TIME=63.89590835571289。全部关闭阴影仍变；275材质unshaded四帧一致、恢复又变；LF四组各6/6对仍变，全LF关闭最大HDR差3.267333984375。LF运行48完整UBO/48depth/16accum分别exact，TIME=55.849998474121094、TAA/jitter0。只定位到受光相关路径，未确定根因；不把关灯/关LF/unshaded当修复，不放宽exact。LF原参数恢复检查通过但无逐材质GPU uniform回读，Scene UBO相同也不代表light/cluster/shadow输入相同。

主相机caster候选绑定Wind130、AmbientLitFixedY34、Hero1，unsupported0，保留fragment/discard及原材质恢复。wuming-v2近级4个阴影查询重复失败；v3加入同步UBO观察后两级各四次重复通过，可能改变时序，不证明v2根因已解。v3真TIME=94.98445892333984、TAA/jitter0；主视图完整UBO稳定，probe仅byte2660变化，不误记全probe字节一致。候选已入独立工程但默认未启用。游仙v1完成208绑定（Wind133/Ambient74/Hero1），unsupported0，两级各四次重复及baseline/disabled/postprobe exact；最终restore有7channel最大2/255差异，整套fail，状态恢复通过、owner.remaining0。先停probe再restore绑定、最后关闭renderer。下一步按变化像素/世界坐标定位受光实际输入并核实观察器/恢复画面，再推进实时双级和局部灯；水底行 CPU 算术模型差异保留，不先验认定生产缺陷或阻塞独立定位。详见`docs/TLV_SUN_PROGRESS_20261126.md`及`workbench/reports/{tlv-shadow-20261126,tlv-drift-20261126,tlv-caster-20261126,water-clock-20261126}/`；旧失败全部保留。


2026-11-27地形专项：`landscape-drift-20261127/gpu-v1` 唯一定位原游仙地形的受光路径；原态/恢复各6/6对最早POST_OPAQUE漂移，union116/20px、最大HDR差0.0697021484375/0.00390625，仅该地形临时unshaded的四帧所有HDR/PNG exact。370材质含目标70uniform前后快照字节完全一致，但不是GPU内部输入回读，也不是生产修复。36上游完整UBO、12折射完整UBO分别exact；两阶段恒定byte2700值15/7，不写48份全同。TIME18.11944580078125、TAA/jitter0，36depth/12accum跨条件exact，综合冻结仍false。

同日独立权重A/B已证明`process/fix_alpha_border=true`改写八层数据纹理：无名/游仙1–4各19747/7257像素，5–8无变化；仅设false后四份导入RGBA均与源exact。生产四份`.import`已设false并重导入5.844秒exit0/错误警告0，PNG保持。生产验证4.734秒exit0，四份RGBA与源全字节一致；实际脚步选材278902+159580=438482次、误差0；旧导入全零权重点345/322归零，物理材质差异2018/1488、音组差异245/45。独立CPU复核全部计数与源权重期望一致，并核对四份旧baseline真实SHA与修改前manifest/run-v1，补齐本次基线来源；无声音播放或桥木行走验收。

验证器v2随后将四份baseline预存SHA纳入启动/结束快照并在实际读入再次严格核对。production-verify-v2正例6.312秒exit0、438482次选材通过；verifier-negative-v2等长改1字节负例0.672秒exit1，在地图统计前以baseline SHA mismatch拒绝，输入前后保持，两个run均错误/警告0。不能把v1只检查长度的局限继续当成当前工具行为；v1外部复核历史保留。

修正后capture-run-v1为99.860秒exit0/错误警告0，两图各六面重复raw、baseline重复、捕获前后主画面exact，状态/时钟恢复通过。integrated-v1两图SH9输入SHA与本次捕获一致，三项CPU投影测试通过。独立复核233+169项全通过，已归档`landscape-weights-20261127/cpu-production-review-v1`。compare-run-v1为122.656秒exit0，两图共四机位分别替换漫反射/反射再恢复，恢复画面exact，434/301shader材质恢复通过；四份SH9/cube资源已备份、部署、SHA核验。house-run-v1为171.469秒exit0，两图各五阶段实际set_inside及室内退出清理通过，不等于门口导航验证。两个default新画面人工未见明显缺材/破面，不是美术验收。

更新后的`post-weight-refresh-cpu-v1`证据true但整体false：原态/恢复最早POST_OPAQUE各6/6对漂移，union82/54px、最大HDR差0.032958984375/0.0184326171875；仅地形unshaded全阶段和PNG exact，材质恢复及36/12份UBO分组保持。权重数据修正后漂移仍在，不能把不同run的像素数减少当因果改善。

`specular-v1`正式wrapper实跑88.469秒exit0，引擎错误0/输入保持；唯一原地形最终shader只加false关闭直接镜面条件，独立diff一行。原/关镜面/恢复POST_OPAQUE分别5/6、6/6、6/6对漂移，union11/22/87px、最大HDR差0.0048828125/0.13427734375/0.050048828125；370材质/70uniform恢复、UBO分组、depth/accum保持，证据true但整体false。单独关镜面不足以消除漂移，不部署该关断；源DXBC的Fresnel缺口另为待测候选，不能当漂移修复。下一步继续局部cone/受光输入。四份小设置白名单提交，PNG/GLB/ctex和大报告不入Git。详见`docs/LANDSCAPE_PROGRESS_20261127.md`；旧失败全部保留，不宣称完整复原。


2026-11-27局部灯继续定位：cone旁路仍漂；direct-v1仅方向灯/无直接灯全5类HDR与PNG exact，仅局部灯仍6/6变。local-input-v1四种常数/灯色/衰减/Lambert均漂，常数受ALBEDO/SH/雾影响不能直接当次数。raw-count-v1唯一地形加fog_disabled+ambient_light_disabled、末尾中性输出及每局部灯1/16，两镜面累加false；12捕获31.734秒exit0/无错误，370材质70参数恢复exact，生产shader未改。原/计数/恢复union159/779/32，仍整体失败。

raw旧906跨run坐标复用失败必须保留：882符合数值编码、873深度exact；24数值invalid全在33跨run深度变化内。独立本run779点均四帧RGB相等且×16严格整数0–31（实0–8），最大变化6、depth/UBO相同；这只证实数值候选，不伪称GPU材质ID。源射线779首先命中源地形但LOD/压缩未重放，155保守内点仍非运行时归属证明。按源码推导tile32/zfar分组，存在同cluster、同源三角相邻像素序列不同，所以单纯整cluster列表变化不足以解释，后续查实际GPU buffer与执行路径。stock API无cluster RID，opaque为set1/binding9；未发现等价subgroup关闭配置，不裁灯。Probe创建不等于当前活跃，mode2 adapter已隐藏旧适配probe。详见docs/LANDSCAPE_PROGRESS_20261127.md及landscape-drift-20261127/{direct-cpu-v1,local-input-independent-v1,raw-count-cpu-v1,raw-count-independent-v1,raw-count-source-ownership-v1,cluster-access-review-v1}/。上游/折射UBO仍分组exact而非两组同值；旧失败与严格门槛保留。TLV/caster未默认启用，非完整复原或美术验收。


2026-11-27外部 GPU 捕获停止点：RenderDoc v1 wrapper 219.297 秒，未注册 Vulkan/未触发，gate 超时后完成12次 live 捕获；370材质/70参数与完整快照、scene/compositor/process_mode/time_scale恢复，输入SHA保持，但Godot因gate failure退出1。v2 qrenderdoc 3.813秒以0xC0000005崩溃，wrapper原子替换遇短锁，已从保留的`.writing`只读恢复失败终态（supervision_finished，96.813秒），旧waiting不代表仍运行。v3 wrapper 43.297秒，目标独享捕获环境后Vulkan注册成功，但地图加载前device lost、Godot 0xC0000005；无receiver，不能声称v3材质/状态恢复通过。三次RDC=0、未replay、未取得实际GPU cluster/light buffer；这三次抓帧阶段生产着色未改。同类GPU抓帧暂停，不将捕获崩溃归因原冻结漂移或断言驱动缺陷。详见docs/LANDSCAPE_PROGRESS_20261127.md；停止抓帧时Fresnel缺口仍为独立研究，后续限定地形部署另记，不能误报漂移修复完成。

本次RenderDoc v1 gate超时后的live CPU审计为`workbench/reports/landscape-drift-20261127/renderdoc-small-evidence-v1/renderdoc-v1-live-cpu-audit-20261127/summary.json`：当前raw-count并集767点，767/767四帧RGB相等且×16严格整数0–31（实0–7），39种序列、最大计数变化6、最大HDR差0.375；没有epsilon/rounding或剔除。36上游/12折射UBO各自组内exact而非48份全同，36depth exact。identity_proven=false；这些是live观测，不是RDC帧或live/RDC同帧证明，overall/capture仍false。旧779点/26序列/0–8与旧906跨run复用失败保持历史，不用本次767覆盖。完整复原及美术验收未完成。


2026-11-27后续有限地形Fresnel修正已部署：生产仅`project/scripts/original_lightfunctions.gd`和`project/shaders/original_lightfunction_receiving.gdshaderinc`两文件，按`source_landscape_compiled=true`在include前加`SOURCE_LF_NATIVE_F90`，缓存键含宏分组，仅地形采用F90=clamp(50*F0.g,0,1)，其它材质保持默认式。两图代表编译实例各8个原PS共16/16重反汇编及hash核对，numeric model1编译数据流支持有限范围；非原版实机RT/SRV/permutation全覆盖。源证据`workbench/reports/landscape-drift-20261127/native-fresnel-scope-v1/`；其中未实施建议为历史时间点，不是当前部署状态。

headless/cache0.406秒、parse0.437秒、两图maps80.343秒均exit0/错误警告空；独立CPU审核80项通过，归档`workbench/reports/landscape-drift-20261127/native-fresnel-runtime-cpu-v1/`。每图四轮全材质检查586/370、各70uniform恢复通过；非地形ShaderMaterial433/300，缓存带宏各1，CPU状态不称GPU回读。每图3张960×540 PNG：无名岛三张exact；游仙村旧式/候选73px87channel、候选/恢复16px18channel，最大均1/255（旧式/恢复80px93channel）。旧式是之前Godot公式而非UE原画，不认画质改善或漂移解决；不将所有差异归因本式。maps-v1中游仙村完整shutdown restored/errors空，无名岛只有四轮目标材料恢复核对，未独立保存全栈shutdown；后续house运行另有两图单独恢复证据。

有限修正后native-fresnel-capture-run-v1为105.5秒exit0/错误警告空；capture-v1两图各两组六面raw逐面SHA exact，baseline_repeat及before_after均0通道，controller_state_restored=true。无名岛另live_time_capture.time_scale_restored、live_time_test.outer_time_scale_restored/process_mode_restored均true；image_equality_asserted=false，不称活跃时间图像exact。两图integrated-v1已生成且原3项CPU投影测试通过，manifest/raw provenance已纳入最终独立审阅。六面重复性不是RenderDoc成功或主相机原漂移修复。

compare-run-v1为109.313秒exit0/错误警告空；两图共四机位分别替换漫反射/反射再恢复，恢复全图0channel，434/301 shader材质及323/275 SH9材质恢复errors空。native-fresnel-cache-deployment-v1记录两图共四份cubemap/SH9已备份部署并SHA核验，“两生产代码文件”不代表未更新派生缓存。house为159.64秒exit0/错误警告空；native-fresnel-production-house-v1两图各五阶段outdoor-initial→indoor-1→outdoor-1→indoor-2→outdoor-2，候选sky保持、室内缓存3/室外0，各阶段errors空；两图均额外从室内shutdown restored，house_outdoors=true，恢复reflection_source2/energy约0.099。这是实际set_inside与清理，不是穿门步行验收。

最终CPU复核`workbench/reports/landscape-drift-20261127/native-fresnel-refresh-cpu-v1/`为322项通过/失败0：30raw有限、冻结六面重复exact、两图各四组SH9系数重算误差0及3解析探针通过、34PNG解码、四机位restore0、四资源source/current/before SHA、house两图五阶段/室内关停记录通过。额外compare重复帧未保存，仅由运行报告支持；未单独序列化compare最终controller/sky身份，不扩展四机位exact。house只证状态记录与10PNG解码，无图像重复/穿门/全图稳定声明；当前积分器非原UE跨面GPU mip/FP16逐位一致。TLV/caster未默认启用，原漂移修复、完整复原及美术验收未完成。9文件本地提交6b78ced243b4ed174172d282d67ff67c8f9a7a2f已形成，文档封存时尚未push，不记作已同步。


2026-11-27 后端对照：原游仙地形隔离、最小 light、最小 fragment 在 Vulkan 均仍冻结漂移；同一 minimal-fragment 诊断显式 D3D12 的五组各四帧，全部 HDR/depth/accum/PNG 六对严格一致，独立 CPU evidence/overall 均 true。两后端实际 driver/method 各 64 次核对，原材质/参数/灯光/几何/控制器/Compositor 恢复通过。marker 只是诊断编码，不是 GPU cluster/material ID 回读，未确诊引擎/驱动根因或永久修复。D3D12 receiver 两图十机位二十 cascade 的 80 raw/isolated 门槛全通过、最大1 halfULP；40端到端另记max3，不放宽门槛。两图caster独立CPU通过，165/208材质及3701/2147几何运行时断言、各四个PNG严格对照与十二个enabled HDR配对全exact；仍为冻结诊断，不称完整实时TLV/UE等价。

可选启动器参数 -RenderingDriver vulkan|d3d12 已部署，两个真实CMD显式D3D12启动及1280×720截图独立16项通过，默认空字符串保留原后端。相同源码/路线/效果/原镜头的两后端四段正常速度实跑，所有move/hold均绘制、支撑通过、房屋各进出2次、time_scale始终1；无名三段D3D12仅6.06–6.44 draw/s、Vulkan16.60–17.20，游仙25.15/31.01，D3D无名模拟/墙钟仅0.806–0.844。保持默认，不部署默认D3D候选；单次带观测开销，不称生产benchmark或流畅。严格CPU各109/110，唯一失败是最终摘要后退出期多写一条空draw（583/584、896/897）；旧失败保留，四段有效证据独立使用。V2已封口，parse及单游仙Vulkan实跑exit0；独立48项通过，报告/原始流均131条，未重跑两后端四段或新增性能结论。细节与证据边界见 `docs/LANDSCAPE_BACKEND_PROGRESS_20261127.md`；完整复原、镜头舒适性和美术验收仍未完成。


实时太阳 TLV 阶段记录（2026-11-27启动，2026-11-28封存，目录/文件名保留启动日期）：新增独立主 RD 太阳体积生产器，未接 worlds/启动器/默认试玩，局部灯 TLV 未实现。无名 D3D12 V1 45.094秒exit0、17独立CPU正反测试；produced8/rejected2/published0/receiver=false，3代表192B ACK与2初始完整UBO核对，165材质恢复及closed通过，不称8份ACK逐核或新compute数值。V2 87.031秒exit0，11请求11完整ACK=8accepted+2house取消+1stop退休；actual snapshot1/frame42保存14完整文件，8 raw/isolated数值门槛全≤1 adjacent halfULP(max1/超1为0)，4端到端max3另列，13独立测试与24作者fixture通过。游仙V2 48.891秒exit0、12测试，11ACK逐核、208caster恢复及closed通过；set_inside状态切换非真实穿门，无新volume数值取样。两图旁路仍receiver=false/published0。

V3已部署14文件，原11仅retry probe恢复/closed状态修正，另3显式诊断；parse2.031秒、无名D3D12 frozen120.015秒/normal93.562秒exit0 clean，独立13测试、作者15fixture通过。frozen首组publication专用owner暂停年龄，6严格HDR/PNG重复及恢复对照均0，太阳贡献有实际差异，不等于画质优劣；27pre_draw×28材质共756CPU观测。normal使用原8帧政策、4不同publication、4提交×28材质共112CPU状态与实际main draw/UBO关联；main-probe TIME差约1.0500/4.7153/1.0082/1.1932秒，读回扰动，不称低延迟。CPU批次记录不称GPU每片元epoch原子性或同帧生产消费。

两图真实穿门Vulkan诊断与baseline均完成，wrapper291.750/186.437秒exit0 clean；各一次起点放置后按原角色/房屋连续输入，非人工操作或set_inside替代。599/575physics tick、9.983333/9.583333模拟秒、进出tick相同，支撑缺失/下穿0；receiver路线51.233074/36.128986秒，baseline14.496570/14.692523秒，单次顺序仪器观测比3.534151/2.459005，非隔离benchmark。83完整ACK，恢复165caster+28receiver/208caster+2receiver及closed通过，独立receiver/baseline审核与18正反例通过。最长fallback首pre_draw至下一active样本跨度14.467410/8.396972秒，包含阻塞和稀疏帧，不是连续光学证明。配对首稿无依据0.1mm轨迹门槛导致游仙0.14219045mm残差失败，原失败保留；修订稿另存并按同输入/时长/tick核对、报告残差，未放宽支撑/ACK/时钟/数值门槛。

V4仅两个计数Shader改为workgroup归约，保留每体素有限检查、计数、浮点公式及纹理写入，不改filter/cull/更新率；独立17静审正反例、作者23fixture重跑通过，首稿审核器新增空行处理失败另存，非Shader失败。全局atomic次数减64倍但shared计数仍在且增加barrier，不称64倍提速或已定位全部成本。新Vulkan pair61.531秒exit0 clean，8原raw/isolated门槛全≤1ULP(max1/超1为0)，4端到端max3独列；13独立+24作者fixture通过，11完整ACK、165恢复closed、receiver=false。两shader实际部署hash单独核对，不能仅凭未含它们的路线12项source snapshot推断保持。

V4两图连续穿门wrapper74.329/79.796秒exit0 clean，各17独立正反fixture过；599/575ticks、66active10fallback/92active7fallback，43/54完整ACK共97，恢复165+28/208+2及closed。无名路线wall22.972856秒(旧51.233074、baseline14.496570)，游仙15.790978(旧36.128986、baseline14.692523)；单次观测分别降55.1601%/56.2928%，仍为baseline1.58471/1.074763倍。max post-draw3.844976/2.722632秒，最长fallback样本跨度6.938066/3.327604秒，包含阻塞/稀疏采样而非连续光学证明。无名三次足点exact，游仙V4与baseline exact、与旧V3最大0.14219045mm残差照报。保留V4但门口停顿仍明显，默认继续关闭，不称生产benchmark、低延迟或流畅性通过。dispatch失败分支、完整局部灯、UE阴影/全图画面/GPU逐片元epoch及正常性能仍未完成。

完整CPU归档包括realtime-sidecar-cpu-v1、realtime-pair-cpu-v2、realtime-sidecar-youxian-cpu-v2、realtime-receiver-independent-cpu-v3、realtime-house-route-independent-cpu-v1、realtime-house-baseline-independent-cpu-v1，以及realtime-workgroup-independent-static-v4、realtime-pair-independent-cpu-v4、realtime-house-route-independent-cpu-v4、realtime-house-youxian-independent-cpu-v4。Git只取14实时源码+1穿门诊断+本AGENTS及进度文档共17小文件；封存时最近远端只读仍18b0c3b、push尚未发生。详见 docs/REALTIME_TLV_PROGRESS_20261127.md；不称完整复原或美术验收。
