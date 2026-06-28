# Recipe Packs Collection Plan

## 1. 目标

- 解决不同用户做饭习惯不同的问题，让 Kitchen Manager 不只服务一种口味或一种家庭场景。
- 从固定菜谱库逐步升级为菜谱包 / recipe packs，让推荐可以围绕“家常、快手、清淡、辣味、高蛋白”等偏好组织。
- 第一阶段只建立候选池和标签规范，不直接修改推荐系统，不直接改现有菜谱数据。
- 后续基于本文件给现有菜谱补 metadata，并逐步新增带标签的新菜谱。

## 2. 第一版菜谱包

| Pack ID | 名称 | 适合场景 |
| --- | --- | --- |
| `basic-home` | 基础家常菜 | 日常家庭做饭、常见中式家常菜、食材容易购买 |
| `quick-solo` | 快手一人食 | 一人吃饭、下班快速解决、步骤少、出餐快 |
| `light-healthy` | 清淡少油 | 清爽、低油、汤菜、蒸煮烤为主 |
| `spicy-sichuan-hunan` | 川湘辣味 | 辣味、豆瓣酱、泡椒、剁椒、重口味下饭菜 |
| `high-protein` | 健身高蛋白 | 鸡胸、鱼虾、牛肉、豆制品、蛋类、适合备餐 |

## 3. 字段规范

每道菜建议包含以下字段：

| 字段 | 说明 |
| --- | --- |
| `id` | 稳定唯一 ID，后续不要随意改名。 |
| `name` | 用户可读菜名。 |
| `packs` | 所属菜谱包，可属于多个 pack。 |
| `cuisine` | 菜系或风格，例如 `chinese-home`、`sichuan`、`western-light`。 |
| `tags` | 用于筛选和解释推荐理由，例如 `quick`、`lunchbox`、`low-oil`。 |
| `coreIngredients` | 核心食材，会影响推荐和缺菜检测。 |
| `stapleIngredients` | 主食基底，例如米饭、面条、乌冬、意面、面包、藜麦。后续推荐可以低权重使用。 |
| `optionalIngredients` | 可替换或可省略食材。 |
| `flavorIngredients` | 决定菜品风味但不属于普通调料的材料，例如豆瓣酱、咖喱块、泡菜。 |
| `seasonings` | 基础调料，例如盐、生抽、糖、醋、胡椒粉。 |
| `equipment` | 需要的设备，例如炒锅、蒸锅、烤箱、空气炸锅。 |
| `timeMinutes` | 预计用时，单位分钟。 |
| `difficulty` | 难度，例如 `easy`、`medium`、`hard`。 |
| `servings` | 默认份量。 |
| `leftoverFriendly` | 是否适合剩菜再加热。 |
| `lunchboxFriendly` | 是否适合带饭。 |
| `spicyLevel` | 辣度等级，例如 `none`、`mild`、`medium`、`hot`。 |
| `oilLevel` | 油量等级，例如 `low`、`medium`、`high`。 |
| `proteinLevel` | 蛋白质水平，例如 `low`、`medium`、`high`。 |
| `sourceType` | 来源类型，例如 `original`、`adapted`、`common-dish`、`ai-draft`。 |
| `sourceNotes` | 来源灵感说明，只记录灵感，不复制原文。 |
| `reviewStatus` | 审核状态，例如 `draft`、`review-needed`、`approved`、`legacy`。 |

字段使用原则：

- `coreIngredients` 影响推荐和缺菜检测。
- `flavorIngredients` 可用于解释口味和后续更细的缺菜提示，但第一阶段不接入业务逻辑。
- `seasonings` 默认不作为缺菜检测核心，除非未来明确把某些决定性风味材料迁入 `flavorIngredients` 或 `coreIngredients`。
- `packs` 用于推荐偏好。
- `tags` 用于筛选和解释推荐理由。
- `sourceNotes` 只记录来源灵感，不复制原文。
- `lunchboxFriendly` 表示适合装饭盒带走，当天吃也算。
- `leftoverFriendly` 表示隔夜或再次加热后仍然相对好吃。

## 4. 版权和来源规则

- 可以参考公开菜谱的菜名、常见食材组合和做法思路。
- 不复制原文步骤。
- 不使用原图。
- 不批量爬取。
- 最终步骤用自己的话简写。
- AI 可以辅助结构化，但必须人工审核。
- 优先收集普通家庭可做、加拿大超市容易买到的菜。

## 5. 候选菜名池

### 基础家常菜 `basic-home`

1. 番茄炒蛋
2. 番茄鸡蛋面
3. 青椒肉丝
4. 土豆丝
5. 麻婆豆腐
6. 鱼香肉丝
7. 宫保鸡丁
8. 咖喱鸡肉饭
9. 照烧鸡腿饭
10. 虾仁炒蛋
11. 蒜蓉西兰花
12. 白菜豆腐汤
13. 肉末茄子
14. 洋葱炒牛肉
15. 香菇滑鸡

### 快手一人食 `quick-solo`

1. 肥牛饭
2. 鸡蛋火腿炒饭
3. 韩式泡菜炒饭
4. 金枪鱼拌饭
5. 鸡蛋酱油拌面
6. 葱油拌面
7. 番茄肥牛面
8. 砂锅米线简化版
9. 鸡腿肉盖饭
10. 牛肉卷乌冬
11. 鸡蛋蔬菜煎饼
12. 豆腐鸡蛋盖饭
13. 酸辣汤面
14. 火腿芝士蛋三明治
15. 墨西哥鸡肉卷

### 清淡少油 `light-healthy`

1. 清蒸鱼片
2. 番茄豆腐汤
3. 冬瓜虾仁汤
4. 白灼西兰花鸡胸
5. 鸡肉蔬菜汤
6. 香菇青菜
7. 蒸蛋羹
8. 豆腐蔬菜煲
9. 蒜蓉蒸茄子
10. 西葫芦炒蛋
11. 三文鱼藜麦碗
12. 烤蔬菜鸡胸饭
13. 鹰嘴豆蔬菜沙拉
14. 黑豆玉米沙拉碗
15. 蘑菇鸡肉糙米饭

### 川湘辣味 `spicy-sichuan-hunan`

1. 麻婆豆腐
2. 回锅肉
3. 辣子鸡简化版
4. 水煮牛肉简化版
5. 酸辣土豆丝
6. 干煸四季豆
7. 小炒黄牛肉
8. 剁椒蒸鱼片
9. 香辣鸡胗
10. 泡椒牛肉
11. 鱼香茄子
12. 口水鸡简化版
13. 辣炒花菜
14. 豆瓣鸡丁
15. 酸菜鱼简化版

### 健身高蛋白 `high-protein`

1. 鸡胸肉蔬菜饭
2. 煎三文鱼饭
3. 牛肉西兰花饭
4. 鸡肉藜麦碗
5. 鸡蛋豆腐碗
6. 金枪鱼玉米沙拉
7. 火鸡肉丸饭
8. 希腊酸奶鸡肉卷
9. 虾仁蔬菜炒饭
10. 牛肉豆类辣椒锅
11. 鸡腿肉烤蔬菜
12. 鸡胸肉意面
13. 豆腐毛豆碗
14. 三文鱼沙拉碗
15. 牛肉生菜卷

## 6. 现有菜谱补标签策略

- 先扫描现有 recipe 数据，建立现有菜谱清单和字段缺口。
- 不直接删除旧菜谱，避免破坏已有推荐、计划、历史数据或用户习惯。
- 对明显不适合普通用户的菜谱标记为 `legacy` / `low-priority`。
- 对常见家常菜补 `packs`、核心食材、难度、时间、设备。
- 无法判断核心食材的菜谱先标记 `review-needed`。
- 不要用 AI 猜得过于自信；AI 只能辅助初稿，最终标签必须人工确认。

## 7. 新增菜谱审核流程

每道新菜谱必须经过：

- 字段完整性检查。
- 食材是否加拿大超市可买。
- 是否适合电陶炉 / 普通厨房。
- 是否有核心食材。
- 是否有明确 `packs`。
- 是否和现有菜谱重复。
- 是否需要人工试做或口味审核。

## 8. 下一步计划

1. 第一步：人工确认候选菜名池。
2. 第二步：抽 20 道生成结构化 JSON 草稿。
3. 第三步：给现有菜谱补 metadata。
4. 第四步：新增 recipe packs 设置和推荐加权。
5. 第五步：逐步扩展更多菜谱包。

## 9. 字段枚举标准

`difficulty` 固定值：

- `easy`
- `medium`
- `hard`

`spicyLevel` 固定值：

- `none`
- `mild`
- `medium`
- `hot`

`oilLevel` 固定值：

- `low`
- `medium`
- `high`

`proteinLevel` 固定值：

- `low`
- `medium`
- `high`

`reviewStatus` 固定值：

- `draft`
- `review-needed`
- `approved`
- `legacy`

`sourceType` 固定值：

- `original`
- `adapted`
- `common-dish`
- `ai-draft`

`equipment` 建议值：

- `stove`
- `pot`
- `wok`
- `pan`
- `rice-cooker`
- `oven`
- `air-fryer`
- `microwave`
- `steamer`

`tags` 建议使用英文短标签，例如：

- `quick`
- `solo`
- `lunchbox`
- `low-oil`
- `high-protein`
- `spicy`
- `soup`
- `noodle`
- `rice`
- `one-pot`
- `meal-prep`
- `vegetarian-friendly`

## 10. ID 命名规则

- 使用小写英文。
- 单词之间用短横线。
- 不使用中文、空格、特殊符号。
- 一旦上线不要随意改 ID。
- 同名不同版本可加后缀，例如：
  - `mapo-tofu`
  - `mapo-tofu-light`
  - `mapo-tofu-quick`

## 11. 核心食材、风味材料和普通调料

- `coreIngredients`：没有它就不像这道菜，会参与推荐和缺菜检测。
- `stapleIngredients`：米饭、面条、乌冬、意面、面包、藜麦等主食基底，后续推荐可以低权重使用。
- `optionalIngredients`：可替换或可省略。
- `flavorIngredients`：决定风味但不是普通调料，例如豆瓣酱、咖喱块、泡菜、椰奶、番茄罐头。
- `seasonings`：盐、生抽、老抽、糖、醋、胡椒粉、料酒等基础调味，默认不参与缺菜检测。

判断原则：

- 如果少了这个材料，菜名和主要口味都不成立，优先放入 `coreIngredients` 或 `flavorIngredients`。
- 如果只是提升香气、颜色或口感，且可以省略或替换，放入 `optionalIngredients`。
- 如果是大多数厨房常备、用量少、不是菜品身份的一部分，放入 `seasonings`。
- 对豆瓣酱、咖喱块、泡菜等材料要谨慎：它们不是普通调料，通常应进入 `flavorIngredients`。

## 12. 多菜谱包示例

- 番茄鸡蛋面：`basic-home` + `quick-solo`
- 麻婆豆腐：`basic-home` + `spicy-sichuan-hunan`
- 三文鱼藜麦碗：`light-healthy` + `high-protein`
- 牛肉西兰花饭：`quick-solo` + `high-protein`
- 蒸蛋羹：`basic-home` + `light-healthy`

## 13. Ingredient Field Precedence

每个食材只能出现在一个 ingredient 字段中。字段优先级如下：

1. `coreIngredients`
2. `stapleIngredients`
3. `flavorIngredients`
4. `optionalIngredients`
5. `seasonings`

字段含义：

- `coreIngredients`：没有它就不像这道菜，参与推荐和缺菜检测。
- `stapleIngredients`：米饭、面条、乌冬、意面、面包等主食基底。后续可以参与推荐，但权重低于核心蛋白 / 蔬菜。
- `flavorIngredients`：决定风味但不是普通调料，例如豆瓣酱、咖喱块、泡菜、椰奶、番茄罐头、照烧汁。
- `optionalIngredients`：可以省略或替换。
- `seasonings`：盐、生抽、糖、醋、胡椒粉、料酒等基础调味。

使用规则：

- 同一个食材不要重复出现在多个 ingredient 字段。
- 如果一个材料既是菜名身份的一部分，又决定风味，优先放入 `coreIngredients`。
- 例如“泡菜炒饭”中的米饭应放入 `stapleIngredients`；泡菜如果主要用于定义风味，可以放入 `flavorIngredients`；不要同时放入 `coreIngredients` 和 `flavorIngredients`。
- “咖喱鸡肉饭”中的咖喱块应放入 `flavorIngredients`。
- “肥牛饭”中的米饭可以放入 `stapleIngredients`。
- “番茄鸡蛋面”中的面条可以放入 `stapleIngredients`，核心仍然是番茄和鸡蛋。

## 14. Recipe Pack Sample Validator

继续新增或调整 `docs/recipe-packs/recipe-pack-samples.json` 后，必须运行本地校验脚本：

```bash
node scripts/validate-recipe-pack-samples.js
```

也可以使用 npm script：

```bash
npm run validate:recipe-packs
```

validator 会检查：

- 顶层结构和 recipes 数量。
- 必填字段是否存在。
- 数组字段类型是否正确。
- `id` 和 `name` 是否重复。
- ingredient fields 是否跨字段重复。
- packs、difficulty、spicyLevel、oilLevel、proteinLevel、reviewStatus、sourceType 等枚举是否有效。
- tags 与字段的一致性 warning，例如 noodle/rice/soup/high-protein/meal-prep/vegetarian-friendly。
- packs 与字段的一致性 warning，例如 quick-solo/light-healthy/high-protein/spicy-sichuan-hunan。

有 error 时脚本会 `process.exit(1)`；只有 warning 时会通过，但需要人工判断是否要修正。

注意：`legacy` 可用于未来标记旧菜谱数据，但 `recipe-pack-samples.json` 是候选样例池，validator 只允许 `draft`、`review-needed`、`approved`。
