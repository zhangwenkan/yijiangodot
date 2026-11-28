# 原版晕影接入（2026-11-28）

无名岛、游仙村现在从各自原地图后期配置读取 `VignetteIntensity=0.6499999761581421`。它在 Bloom 和曝光之后、Film/LUT 之前乘入 HDR。没有重新调色、整体压暗、修改水体参数或模型，也没有修改正式孤岛工程。

## 原配置与读取边界

`original_source_renderer.gd` 读取 WorldEnvironment 的 `ue_postprocess`，仅支持一个已启用、unbound、BlendWeight 恰好为 1 的审核过的原生后期体积，以及明确开启的晕影 override、[0,1] 内有限数值。多体积、禁用、局部体积、非完整权重、未知类、缺必要字段和错误值记录 `unsupported` 并使用强度0，不猜测 volume blend。

两图 cooked 配置省略的 bEnabled/BlendWeight 已由安装版原生构造函数和反射描述符确认默认 true/1；JH 子类没有覆盖它们。因此只对已核对的 JHPostProcessVolume/Engine.PostProcessVolume 允许这两项省略。其余必要字段不可省略。`report.vignette` 包含状态、原值、实际强度、默认补齐项、证据和拒绝原因。

Film 提供 `set_source_vignette_intensity()`；诊断 setter 保留为同一参数的别名。原 IntoHouse 字节码未修改 Vignette，OutoHouse 恢复完整缓存 Settings，因此进出屋保持该值；这不代表未知剧情状态已全部复原。

小型来源、原生地址/描述符、公式与历史 CPU 数值证据见 [source-vignette-evidence-20261128.json](source-vignette-evidence-20261128.json)。不随 Git 分发原 EXE、DXBC、完整反汇编、截图或大分析。

## 可复跑的轻量验证

在仓库根目录执行以下 PowerShell 命令；Godot 和本地地图资源须按 [LOCAL_RESOURCES.md](LOCAL_RESOURCES.md) 准备。路径均从当前仓库解析，报告只在明确指定 `--output` 时写入；缺资源会失败，不会跳过真实地图检查。

```powershell
$repo = (Get-Location).Path
$report = Join-Path $env:TEMP 'source-vignette-policy.json'
$log = Join-Path $env:TEMP 'source-vignette-policy.log'
& (Join-Path $repo 'tools/godot/Godot_v4.7.2-stable_win64_console.exe') --headless --path (Join-Path $repo 'project') --script (Join-Path $repo 'tools/verification/verify_source_vignette_policy.gd') --log-file $log -- --output=$report
```

测试直接调用项目内的实际 `resolve_source_vignette()`，加载两图现有原配置，共46项正反例：两图省略默认、显式完整参数、0/1端点、多体积、缺字段、错误类型、未知类、禁用、局部范围、非1权重、NaN/Inf及越界值。只加载脚本和JSON，不实例化地图或 compositor，不启动 GPU 渲染。

最后一次实际执行46项全部通过、exit0、错误/警告0。报告包含本次实际 renderer/config SHA，测试源码可随仓库提交。两份生产 GDScript 的 check-only 已通过。初次测试的 NaN JSON warning 与首次未指定 writable log 路径的错误记录仍保留在本地审计目录；修订后重新运行 clean，没有覆盖旧失败。

历史 CPU 公式检查覆盖4,377,600个像素，float32 对独立 float64 最大绝对误差2.2002822053e-7；强度0的400,012组 Film 输入字节检查 exact。它们是公式与输入检查，不是原游戏 GPU 逐像素等价。

## 画面范围与剩余问题

此前冻结 A/B 的32张显示PNG完整解码，四机位重复/恢复逐RGB字节一致。实际水面ROI中，.65晕影使无名左下近水显示Y降低83.88、船右降低2.02；游仙中央只降低0.81、左侧高亮水降低26.87、右下水降低36.08。Y为0–255编码亮度，不能解释成HDR能量百分比。

晕影修正主要影响边缘，不能解决中心水体偏亮。反射/SH9干预也明显改变水面，但各后处理差值不能相加当独立能量贡献，也不支持直接关闭某层。完整TLV、Water BRDF/反射过滤和其它已记录差异仍需继续核对。

默认场景 GPU 后续验证未完成：Vulkan v1 保存无名五次室内外状态，强度均约 .65，随后游仙首次绘制 device lost；v2 在无名首次载入、Film 安装前已 device lost。D3D12 v3 则在 command queue 初始化失败，未进入地图。三次失败均保留，Windows 另有早于该验证的 AMD TDR 记录，但没有定位最终根因。已停止 GPU 测试，未录本轮正常速度视频。详见 `VISUAL_RESTORATION_PROGRESS_20261128.md`；CPU/A/B 通过不代表默认稳定或完整复原验收。
