# 原场景中三个景深后发射器

本模块在默认 HDR 景深之后、Bloom 与 Film 之前合成无名岛的两组火焰和游仙村的萤火虫。依据安装版 cooked 材质继承、UMaterial 构造默认与 `r.SeparateTranslucency` 注册默认；尚未取得原版当前帧的 CVar 或 GPU 绘制捕获。

| 原组件 | 材质 | 处理 |
|---|---|---|
| 无名岛 `PS_HuoBa_12` | `TorcheFire_fwd3_D_Inst` | 原序列帧、轴锁定、深度淡出与高度雾 |
| 同组件 | `Flame_Inst1` | 原帧图、颜色与高度雾 |
| 游仙村 `BP_Fireflies2` | `M_Fireflies` | 原径向透明度与发光表达式 |

Water、Ocean、瀑布、烟和水花显式关闭该源选项；落叶为 Masked。它们保持各自原处理阶段，不随此模块移到景深后。

## 数据与恢复

模块上传既有 Blender 四边形的顶点、UV、索引以及现有粒子实例数据，不生成模型或改动原模拟。全分辨率 RGBA16F 层使用真实 opaque 深度做反向 Z 遮挡，随后以预乘颜色合成；保留底图 alpha。材质优先级和透视距离用于跨组排序；同组件等键时保留原 emitter 数组的 Torch → Flame 顺序。原资产及 UE4.26 对照渲染链支持这个顺序；Godot 的等键登记顺序不作为原版标准。

GPU 初始化成功后才隐藏原渲染实例，Node 的 visible、layers 与模拟保持。失败时恢复原绘制；上游景深失败时同时移除已停用的景深包装并恢复相机属性和所有权标记。正常切图先恢复本模块，再恢复景深与其他渲染模块。外部直接修改 compositor 的 effects 数组不属于当前已验证的所有权接口。

已有诊断脚本临时将上游景深 `enabled=false` 时保留同一效果、相机属性与所有权，独立层继续合成；重新开启后沿用原景深实例。真正的 `failed` 信号和显式 `owner.restore()` 才结束上游所有权并还原相机链。直接切换本模块自身 effect 的 enabled 不是提供的暂停接口；需要退出时调用 adapter.restore()。故障注入验证的是恢复链，不代表覆盖引擎的所有资源分配故障。

## 验证与边界

核心 GPU 验证入口为 `res://scripts/verification/verify_source_separate_translucency.gd`，CPU 检查为 `tools/verification/analyze_source_separate_translucency.py`。完整本地记录在 `workbench/reports/transparency-order-20261126/`。

配齐本地原场景资产、同版本 Godot 和带 NumPy 的 Python 后，在仓库根执行：

```powershell
python tools/verification/run_source_separate_translucency.py
```

运行器会在 `workbench/reports/` 创建新目录，保存命令、引擎日志、图像和 CPU 结果，拒绝覆盖旧记录。可用 `--godot`、`--out`、`--timeout` 指定路径和时限。回归会主动注入一次景深失败，因此必须出现且只允许出现一条精确匹配的 `ERROR: Source HDR DOF: intentional integration diagnostic`；其他错误或画面/状态断言失败都会令验证失败。该测试需要实际 GPU 渲染，不能加 `--headless`。

- 黑底单发射器的正常、UV、透明度、发光输出已与原 Godot 材质严格比较；真实源几何下的逐层 UV/遮挡检查保持。
- 独立层与直接混入背景的浮点舍入结构不同；正常火焰叠在非零背景上的 RGB 并非逐位一致。已保存全部差值，不能把半精度合成检查解释成原版图像等价。
- 两组火焰的组合差异已用仅诊断的反序实验定位；生产保留原数组顺序。游仙村少量背景像素在未修改场景的重复捕获中仍变化，根因尚未确定。
- 当前是单视图、全分辨率层，并非 UE 动态分辨率 SeparateTranslucency、完整 Diaphragm 景深或原 Cascade 随机序列的完整复刻。

技术检查不等于完整复原或美术验收。具体运行结果和失败记录见仓库 `docs/RESTORATION_PROGRESS_20261126.md`。
