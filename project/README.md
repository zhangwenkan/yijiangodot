# 无名岛与游仙村 Godot 复原代码

入口为 `project.godot` → `worlds.tscn` → `scripts/worlds.gd`。当前代码包含行走、碰撞、原导航数据适配、环境动态、房屋状态、原材质适配和后期渲染。WASD／方向键行走，F 自由观察，Home 回码头，Tab 隐藏界面。

本仓库只提交核心代码和小型配置，`assets/`、Blender 源文件和 Godot 导入缓存不在 Git 中。完整地图运行需要另外恢复对应的本地资源；参见仓库根 `README.md` 和 `docs/LOCAL_RESOURCES.md`。

多个名称含 `_candidate` 的目录已经被默认渲染路径引用，应保留；目录名称不表示可以删除。项目使用 Godot 4.7.2 标准单精度桌面版和 Forward+。

完整一比一复原尚未完成。原 TLV／阴影、反射卷积、完整透明景深、部分原切线与细分、剧情行为、全图通行和长期性能仍有差异；检查通过不等于美术验收。当前约束见根目录 `AGENTS.md`。
