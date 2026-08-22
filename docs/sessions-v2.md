# 会话存储 v2 —— 超长会话方案(设计稿)

## 现状痛点(全部实测/审读确认)

| # | 现象 | 根因 | 实测 |
|---|------|------|------|
| 1 | `-s` 找不到会话 | `open()` 全量读,上限 256KB;会话 286KB 即超限被静默跳过 | 客户目录实机 |
| 2 | `loadMessages` 16MB 上限 | 超限 `catch return &.{}` —— **静默载入空历史** | 审读 |
| 3 | 列表慢/占内存 | `list()` 对**每个**会话全量读文件提取 meta | 审读(N×全读) |
| 4 | web 每轮全量重写 | `saveWebTs` tmp+rename 整写文件,超长会话轮轮 O(size) | 审读 |
| 5 | `setTitle` 全读全写 | 为改首行标题读全文件+原子重写;256KB 限同雷 | 审读 |
| 6 | 超长启动 token 灾难 | 载入即全量进上下文(无分层) | 审读 |
| 7 | 崩溃/坏行 | 无半行容错策略(逐行 parse 有 skip,但无显式标记) | 审读 |

## v2 结构

```
~/.piz/sessions/<cwd-slug>/
  <id>.meta.json    # 轻量元信息(约 0.5KB):cwd/started/title/msg_count/bytes/预览
  <id>.jsonl        # 纯追加消息日志(不变;首行仍写内嵌 meta 供旧版回退)
```

三原则:

1. **扫描零开销** —— list/open/findById/describe 只读 `.meta.json`(500B×N 全扫无压力),永不读正文。`describe` 的预览/turns 由 meta 提供;缺 meta 的老文件回退读首行内嵌 meta(当前逻辑),**渐进兼容,零迁移**。

2. **写只追加** —— CLI 已是追加;web `saveWebTs` 由「每轮全量重写」改为**追加**(与 CLI 同一 `append` 路径)。`setTitle` 只改 `.meta.json`,**不再碰正文**。正文重写仅剩低频操作(`truncate`/undo)。

3. **读分两层** —— `loadMessages(limit)`:
   - 文件 < 8MB:全载(现状,无锚)
   - ≥ 8MB:**尾部窗口 3MB**(从**行边界**起步:定位后跳到下一个 `\n`) + 折叠锚消息:
     `{role:"system", "content":"[历史折叠] 当前窗口为最近 3MB;此前历史见文件或 /load 全量。"}`
   - 超 16MB 上限不再静默空;锚点保证可续可用

## 兼容与回退

- 老文件(meta 内嵌首行、无 `.meta.json`):open 回退首行;首次写入时**生成 meta 镜像**,此后走轻量路径
- **不迁移**:旧文件原样,新文件新行为;两代互读
- 文件尾坏行/半行:逐行 parse,失败跳过(现状已有),追加继续

## 已知取舍(明说)

- 尾窗 = 上下文从「最近窗口」开始,**更早历史不进模型上下文**。语义连续性靠:折叠锚提示 + 会话内 `compact`(现有机制,折叠摘要留内存)+ 用户可用 `/load` 全量。
- 深折叠(窗口外历史自动生成摘要文件、`folded.md` 落盘)**不做在本次**——依赖模型调用与成本策略,与 evolve 体系耦合,单独成单。

## 实施清单

1. meta 镜像写入/读取(writeMeta/setTitle/open/describe)
2. loadMessages 尾窗 + 锚 + 上限失败明确化
3. web 追加化(saveWebTs/loadWeb)
4. 测试:超限载入只取尾窗;meta 扫描快;web 追加不膨胀;旧格式兼容
