---
name: commit-msg
description: 起提交说明。规范diff、断句、动词开头,客言"写提交"时用。
---

# Commit Msg

读 `git diff --staged`(无暂存则 `git diff`),起一行式提交说明:

1. 动词开头,不过 72 字:fix/add/refactor/test/docs 择一冠之。
2. 涉多文件则摘其要,不罗列路径。
3. 拿不准类型,用 `chore` 兜底并在正文一句解释。
