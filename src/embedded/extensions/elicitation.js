// elicitation —— ask_user 工具:信息不足时向用户提问。内嵌出厂件,默认关,同名覆写。
// 原件本不触 UI:仅回执指令文本,agent 主循环见回执即停轮,用户下一条消息才是答案。
piz.registerTool({
  name: "ask_user",
  description: "Ask the user a clarifying question when information is insufficient to proceed.",
  parameters: {
    type: "object",
    properties: { question: { type: "string", description: "Question to ask the user." } },
    required: ["question"],
  },
  execute(args) {
    const q = String(args && args.question || "");
    if (!q) return { error: "error: ask_user requires 'question'" };
    return { content: "The user has been asked: " + q +
      "\nSTOP and present this question to the user in your reply. Do not guess or continue until the user answers in their next message." };
  },
});
