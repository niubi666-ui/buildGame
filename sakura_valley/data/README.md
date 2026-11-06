# 游戏数值配置

这里的文件都可以直接用记事本改，改完重新打开游戏就生效，不需要重新编译。

| 文件 | 内容 |
|---|---|
| `enemies.json` | 兵种：血量、速度、搭桥和爬坡能力、击杀奖励、颜色 |
| `towers.json` | 防御塔数值和摆放规则 |
| `effects.json` | 塔的攻击特效：开火、拖尾、命中、着火、减速、敌人倒下、升级、后坐力 |
| `terrain_tools.json` | 改地形的价格、笔刷速度、预设形状、隧道规则、手感反馈 |
| `levels/index.json` | 选关界面的关卡顺序，“试验场”按钮打开哪一关，以及两星的血量分界 `two_star_health`（默认 0.5：剩一半及以上两星） |
| `levels/level_01.json` | 第一关：起始金币、家园血量、地图形状、入口、每一波敌人、镜头 |
| `levels/level_02.json` ~ `level_06.json` | 第二到第六关：云海裂谷、浮空群岛、樱川三角洲、火山环城、横江渡口 |
| `levels/level_0X_balance.json` | 第二到第六关各自的平衡测试打法（第一关的打法写在脚本里） |
| `levels/sandbox.json` | 试验场：旧的樱花山谷，用于自动测试 |

## 常用的字段

**兵种（`enemies.json`）**

- `walk_speed`：平地速度，米/秒。
- `uphill_penalty`：上坡减速程度，越大越怕上坡。
- `climb_slope`：坡度超过它就算“爬坡”（0.75 约等于 37°）。
- `climb_speed`：爬坡速度。
- `boat_speed`、`embark_time`：在水里的速度和下水要花的秒数（划船和游泳都用这两个）。
- `water`：怎么过水。`boat` 划船（船队）；`swim` 游泳，只露出上半身；`dive` 潜水，从一个水格游到下一个水格时整个人在水下，塔打不到，水面上只看得到一个暗影，下水和上岸的那一步露出水面。不填就是 `boat`。
- 从水里上岸时，岸比水面陡（超过 `climb_slope`）就得按爬坡算，不能一步跨上去。
- `bridge_time`：整支队伍每搭 1 米桥要花的秒数。
- `crew`：多少人算一支完整的搭桥队伍。

**防御塔（`towers.json`）**

除了 `stars` 和 `rules`，每个顶层键是一种塔（现在有 `normal` 炮塔、`catapult` 投石塔、`sniper` 狙击塔），建造栏按文件里的顺序排按钮。每种塔可以有这些字段：

- `key` 建造快捷键，`icon` 按钮图标，`tip` 按钮提示，`model` 用哪套模型（cannon、catapult、sniper），`pivot_height` 炮口离塔底多高（影响塔从多高往下打）。
- `lob`：填 true 是抛射，距离按水平算，山丘挡不住，360° 都能打（`cone_degrees` 填 360），卡片上不显示瞄准。
- `min_range`：多近以内打不到。
- `height_damage`、`height_damage_max`：塔比目标每高 1 米多多少伤害，最多多多少。
- `shot_speed`：子弹每秒飞多少米；抛射时是水平速度。

- `cone_degrees`：圆锥张角。
- `range`：射程，米。
- `damage`、`cooldown`：每发伤害、两发之间的秒数。
- `splash_radius`：范围伤害半径。敌人越密集，一发打中的人越多。
- `splash_targets`：一发最多打中几个人。没有这个上限的话，砌墙把敌人堵成一团就太强了。
- `upgrades`：升级树。每个节点有 `id`、`name`、`cost`、`tip`（卡片上的说明）、`change`（升级后改成的数值，字段同上），以及可选的 `next`（下一层的两个选项）。树可以任意深，选过一条分支就不能换，只能拆了重建。`change` 里还能用这些效果：
  - `height_reach`、`height_reach_max`：塔比目标每高 1 米多多少射程，最多多多少米。
  - `fire_seconds`、`fire_radius`、`fire_dps`：落点燃烧几秒、火圈半径、每秒伤害。
  - `slow`、`slow_seconds`：命中减速的比例和时长。
  - `knock_climbers`：填 1 时，把正在爬坡的敌人震回开始爬的地方，并让它躺 1 秒。
- `stars`：走完升级树之后的星级强化。`costs` 是每一星的价格，几项就是几星封顶；`damage_bonus` 是每星增加的伤害比例（按终极形态的伤害算）。
- `rules.refund`：拆塔返还的比例，按建造和所有升级花的钱一起算。

**改地形（`terrain_tools.json`）**

- `cost_per_cubic_metre`：每立方米土的价格，笔刷和预设都用它。
- `presets`：一键放置的地形。`key` 快捷键，`shape` 形状（`bell` 山丘、`ridge` 土堤、`box_pit` 方坑）。
  - 土堤的 `fit_ends` 打开后，土堤会沿长边自动伸长，直到两头都碰到比堤顶高的山坡，玩家放偏一点也能堵住路。`min_length`、`max_length` 是伸缩的上下限。在 `max_length` 内碰不到高地的一头保持原长 `length`，预览时立一根红柱，提示敌人会从那里绕过。
  - `adjust`：玩家可以调的尺寸，放置时显示在底部工具栏，代替笔刷的“大小、力度”。每项有 `key`（对应上面的字段，如 `length`）、`name` 显示名、`min`、`max`、`step`。`wheel` 填 `ctrl` 或 `alt` 时，可以用这个键加滚轮调整，每格两步。土堤的长度旁边有“自动”开关，打开时按 `fit_ends` 自动伸长；玩家拖动长度或关掉开关后，土堤保持玩家定的长度，可以故意留缝，没接上的一头照样立红柱。
- `tunnel`：`cost_per_metre` 每米价格，`portal_cost` 单个洞口价格，`max_length` 最长多少米，`refund` 填平时返还的比例。
- `routing`：`tunnel_speed` 隧道里的速度倍率，`max_span` 敌人最长搭多长的桥。
- `feel`：灌水速度、树倒下的时间、地面震动的音量和镜头抖动。

**关卡（`levels/*.json`）**

- `start_gold`：起始金币。
- `home_hp`：家园血量，每个敌人抵达扣 1。填 0 表示没有胜负。
- `waves`：每一波由若干 `groups` 组成：`type` 兵种，`gate` 从哪个入口来，`count` 人数，`interval` 出发间隔，`delay` 开战后延迟几秒。
- `map.no_build_zones`：不能改地形和建塔的圆形区域。
- `map.no_build_areas`：不能改地形和建塔的长方形区域，每项 `{ "rect": [x0, z0, x1, z1], "reason": "玩家想建时看到的提示" }`。第六关用它把整个西岸设成敌岸。
- `map.route_choices`：路线对比里要算的走法，比如“走西路”会算出必须经过那个点要花多久。
- `views`：这一关的镜头位置，第一个 `view_order` 是开局镜头。
- `card`：选关卡片上的介绍。`difficulty`：卡片上的难度花瓣数（0–4）。`name` 里“：”前面的部分显示成小标签，后面是卡片标题。

## 塔的模型和颜色（`tower_models.json`）

- `models`：每种塔（和 `towers.json` 里的 `model` 对应）的模型文件 `file`、节点名前缀 `prefix`，以及 `rest_pitch`：没瞄准时炮口俯仰多少弧度（投石臂靠它放平）。
- `vane_turns_per_second`：风车每秒转几圈。
- `materials`：模型里每种材质的颜色和粗糙度（键是 Blender 材质名去掉 `WT_`）。`glow` 是发光亮度，用在炉火和星石上。
- `cloth`：帆布的底色。
- `accents`：强调色色板。帆布条纹、旗子、彩绳都用强调色，`base` 是没升级时的颜色。
- `upgrades`：每个升级的样子。`accent` 是 `accents` 里的颜色名，走得越深的升级说了算；`pattern` 只写在一级升级上，定这条线的条纹：`bands` 横条（默认）、`vertical` 竖条、`dipped` 染色下摆加一道横条。

改这里不用重新导出模型。哪个升级显示哪些部件写在模型里，要改它得改 `art/models/towers/build_windmill_towers.py` 再导出，见 `HANDOFF.md` 的“塔模型”。

## 攻击特效（`effects.json`）

每种塔的样式在 `styles` 里：`launch` 开火，`trail` 拖尾（`trail_rate` 每秒几团），`impact` 命中。命中特效按爆炸半径缩放，`impact_radius` 是 1 倍大小时的半径。`on_fire_impact`、`on_slow_impact` 是带火、带减速的炮弹额外加的特效；`death` 敌人倒下；`upgrade` 升级；`fire_embers` 着火地面冒火苗和火星（`per_second` 是 6 米火圈每秒几次）。`recoil` 是开火时炮管后退多少米、多少秒复位、炮口上跳多少弧度，以及投石臂甩到多少弧度、甩出和收回各几秒。

`recipes` 里每个特效是一组发射器。每个发射器的字段：

- `kind`：`puff` 烟团或尘团，`glow` 发光点，`streak` 拉长的火花，`ring` 贴地扩散的圈，`chunk` 碎块，`beam` 从枪口到目标的一道光，`petal` 花瓣。
- `count` 个数，可以是小数（多出的部分按概率多生一个）。`count_scale` 为真时个数跟着爆炸半径变。
- `size` 出生和消失时的直径（米），`size_jitter` 随机浮动。`scale_size` 为真时跟着爆炸半径变。
- `life` 存活秒数范围。`speed` 初速度范围（米/秒），`scale_speed` 为真时跟着爆炸半径变。
- `dir` 方向：`up` 向上散开，`sphere` 四面八方，`flat` 贴地向外，`forward` 顺着开火方向（`cone` 是锥角，度）。
- `drag` 空气阻力，`gravity` 重力（负数往上飘），`spin` 转速，`stretch` 火花按速度拉长多少，`spread` 出生位置随机散开的半径，`lift` 额外向上的速度。
- `color` 一个或几个颜色（随机挑一个），写 `tint` 表示用敌人自己的颜色。`alpha` 不透明度，`glow` 发光亮度。

顶部的 `size_scale`、`speed_scale` 一次放大、加快所有特效。`pool` 是同时存在的粒子上限，`max_new_per_frame` 是每帧最多新生多少个。

## 用地貌拼地图（`"generator": "composed"`）

第二到第五关的地图都由 `scripts/maps/composed_shape.gd` 生成：先铺一层平地，再按 `features` 的顺序一个个叠上去。坐标单位是米，地图从 -160 到 160，北边是 z 负方向（敌人一般从北边来）。

地图本身的字段：

- `ground`：平地高度。`noise`：大起伏的幅度。`detail`：细小起伏的幅度。`seed`：随机种子，改了起伏就变。
- `outside`：填 `"void"` 表示地图外面全是云海（浮空岛），否则是连绵的山。
- `void_level`：低于这个高度的地面算“悬空”，谁都走不过去也爬不过去，只能搭桥，也不能建塔。玩家把地挖到这个高度以下，就等于把地挖穿了。不填就没有悬空。
- `void_floor`：悬空处的地面高度（藏在云下面）。`cloud_height`：云海的高度，填了才会画云海。
- `flowing_water`：填 `true` 时，水只从源头（`water_seeds` 和带水的沟）流进来，在下游筑坝，坝下的水会全部干掉。不填时，所有一开始就有水的地方都会一直有水。
- `mud_speed`：河水被抽干后，原来的河床变成烂泥，在上面走和爬的速度乘以这个数（比如 0.4）。不填就是 1，没有烂泥。只有第六关打开了；第四关打开后，敌人会改成在干河道上搭桥，原来设计的解法就不成立了。
- `rim`：地图四周的一圈山，`height` 高度，`width` 宽度，`openings` 是缺口 `[x, z, 半径]`（入口和河流要留缺口）。
- `home`：家园位置 `x`、`z`，到达半径 `goal_radius`，家园周围压平的高度 `height`。
- `roads`：画在地上的土路 `points`，只是装饰，敌人照样走最快的路。路边不长树，每隔 70 米放一盏灯笼。
- `rocks`：成片的石头 `[x, z, 半径]`。`keep_clear`：不长树的圆 `[x, z, 半径]`。
- `route_labels`：路线穿过哪个圆，就在路线预告里叫什么名字，比如“过石拱”。都不经过时，搭了桥叫“搭桥”，坐了船叫“坐船”。

`features` 里每一项的 `type`：

| 地貌 | 形状 | 主要字段 |
|---|---|---|
| `mesa` | 椭圆形台地（浮岛、岬角） | `x`、`z`、`rx`、`rz`，可选 `yaw`（度） |
| `ridge` | 沿折线的一道山梁（石拱、长墙） | `points`、`width` |
| `trench` | 沿折线的沟（裂谷、河道），加 `"water": true` 就是河 | `points`、`width` |
| `ramp` | 沿折线的坡道，高度按 `levels` 逐段变化（连接浮岛的石梁、倾斜的长岛） | `points`、`levels`、`width` |
| `flat` | 圆形平地 | `x`、`z`、`radius` |
| `hill` | 圆形小山，叠加在原地面上 | `x`、`z`、`radius`、`height` |
| `lake` | 椭圆形湖，自动有水 | `x`、`z`、`rx`、`rz`、`depth` |
| `ring` | 环形山壁，`gaps` 是缺口 `[角度, 半宽米数]`，角度 0 朝东、-90 朝北 | `x`、`z`、`radius`、`width` |

高度：写 `top`（台地、山梁、平地、环的顶）或 `bottom`（沟、湖的底）就是绝对高度；不写时用 `height`/`depth`，相对 `ground` 计算。`ramp` 只看 `levels`。

共用字段：`edge` 边缘过渡的米数（越小越陡，2–3 米就是悬崖），`rough` 边缘的不规则程度（米），`bumps` 顶面的起伏，`op` 叠加方式：`max` 只抬高、`min` 只挖低、`set` 直接替换、`add` 叠加。沟和湖默认 `min`，坡道和平地默认 `set`，小山默认 `add`，其他默认 `max`。

改完地图可以用下面的命令看敌人怎么走，并给每个镜头截图（存到 `D:/Temp/lv/l2`）：

```
Godot_v4.7.2-stable_win64_console.exe --path . -- --level=level_02 --levelcheck=D:/Temp/lv/l2
```

再加 `--trace` 会把每个兵种的路线每隔约 8 米打印一个点（x, z, 高度, 走法），用来看敌人在哪里下水、在哪里爬坡。`--watch=x,z,镜头距离` 会不放塔打第一波，从 `--watchfrom=` 指定的秒数开始，每 3 秒对着那个点截一张图，存到 `--levelcheck=` 的目录，用来看敌人走过时的样子。

## 调完数值后检查平衡

下面的命令会用 23 种打法把第一关自动打一遍，不用等待也不开画面，结果写在控制台里，`BALANCE ok` 表示结局和设计一致。

```
Godot_v4.7.2-stable_win64_console.exe --headless --path . -- --balance=all
```

打法写在 `scripts/balance_test.gd` 的 `STRATEGIES` 里。第一关的设计是：堵一条路或挖隧道能赢；不动脑子的随手摆放（`n_naive_*`）、封死两条路、把塔全放一边都会输；不改地形、但按覆盖最多来分开放塔（`a_`、`h_`、`j_`）输赢都可以。

其他关加 `--level=level_02` 这样的参数，打法读 `data/levels/level_02_balance.json`。除了第一关的字段，地形步骤还可以写 `{ "dig": [x, z, 半径, 挖到的高度] }` 和 `{ "raise": [x, z, 半径, 堆到的高度] }`，按玩家的土方价格扣钱。`goal` 是期望结局：`win`、`lose` 或 `any`（不检查）。`stars` 是期望星数，写一个数或 `[最少, 最多]`，有它时不看 `goal`。`naive: true` 表示不动脑子的摆法：每座塔放在离区域中心最近、能打到路线的地方。`upgrade_first: true` 表示第一波就按 `plan` 升级，先把每座塔升完再建下一座（少建塔、塔更强）；不写时第一波只建塔，升级用之后的赏金。

结果里每波会写哪些兵种到了家，比如 `arrived 5 (walker 4, diver 1)`。加 `--gold=12000` 可以不改关卡文件、换一个起始金币来跑。

JSON 不支持注释，改的时候注意逗号和引号。如果写错了，游戏启动时会在控制台报告出错的文件。
