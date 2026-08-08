export function activate(api) {
	let toolCount = 0;
	const badge = document.createElement("span");
	badge.className = "example-plugin-badge";
	badge.textContent = "tools 0";
	api.ui.mount("status", badge);

	api.ui.button("header", {
		label: "总结",
		title: "让模型总结当前会话",
		onClick: () => api.send("请简短总结当前会话。"),
	});

	api.on("tool_result", () => {
		toolCount += 1;
		badge.textContent = `tools ${toolCount}`;
	});

	api.renderTool("web_search", ({ output, error }) => {
		const box = document.createElement("div");
		box.className = `example-search ${error ? "is-error" : ""}`;
		const title = document.createElement("strong");
		title.textContent = error ? "搜索失败" : "搜索结果";
		const body = document.createElement("pre");
		body.textContent = output || "(无输出)";
		box.append(title, body);
		return box;
	});

	api.toast(`${api.name} 已加载`);
}
