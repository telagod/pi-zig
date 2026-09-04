// diff.ts —— Git Unified Diff 解析与行级比对渲染器
import { FileDiff, Hunk, DiffLine } from "./types";

export function parseUnifiedDiff(rawDiff: string): FileDiff[] {
  if (!rawDiff || !rawDiff.trim()) return [];

  const files: FileDiff[] = [];
  const lines = rawDiff.split(/\r?\n/);
  let currentFile: FileDiff | null = null;
  let currentHunk: Hunk | null = null;
  let oldLineNo = 0;
  let newLineNo = 0;

  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];

    if (line.startsWith("diff --git ") || line.startsWith("--- ")) {
      // 提取文件名
      let path = "";
      if (line.startsWith("diff --git ")) {
        const parts = line.slice(11).split(" ");
        if (parts.length >= 2) {
          path = parts[1].replace(/^[ab]\//, "");
        }
      } else if (line.startsWith("--- ")) {
        path = line.slice(4).trim().replace(/^[ab]\//, "");
      }

      if (!currentFile || currentFile.path !== path) {
        currentFile = {
          path: path || "unknown",
          status: "modified",
          additions: 0,
          deletions: 0,
          hunks: [],
          raw: line + "\n",
        };
        files.push(currentFile);
        currentHunk = null;
      } else {
        currentFile.raw += line + "\n";
      }
      continue;
    }

    if (line.startsWith("+++ ")) {
      const p = line.slice(4).trim().replace(/^[ab]\//, "");
      if (currentFile) {
        if (p && p !== "/dev/null") currentFile.path = p;
        currentFile.raw += line + "\n";
      }
      continue;
    }

    if (line.startsWith("@@ ")) {
      if (!currentFile) {
        currentFile = {
          path: "diff",
          status: "modified",
          additions: 0,
          deletions: 0,
          hunks: [],
          raw: "",
        };
        files.push(currentFile);
      }
      currentFile.raw += line + "\n";

      // 解析 @@ -a,b +c,d @@
      const match = /@@ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)? @@/.exec(line);
      if (match) {
        oldLineNo = parseInt(match[1], 10);
        newLineNo = parseInt(match[2], 10);
      } else {
        oldLineNo = 1;
        newLineNo = 1;
      }

      currentHunk = {
        header: line,
        lines: [],
      };
      currentFile.hunks.push(currentHunk);
      continue;
    }

    if (!currentHunk || !currentFile) {
      if (currentFile) currentFile.raw += line + "\n";
      continue;
    }

    currentFile.raw += line + "\n";

    if (line.startsWith("+")) {
      currentFile.additions++;
      currentHunk.lines.push({
        type: "add",
        content: line.slice(1),
        newNo: newLineNo++,
      });
    } else if (line.startsWith("-")) {
      currentFile.deletions++;
      currentHunk.lines.push({
        type: "del",
        content: line.slice(1),
        oldNo: oldLineNo++,
      });
    } else if (line.startsWith(" ") || line === "") {
      currentHunk.lines.push({
        type: "context",
        content: line.startsWith(" ") ? line.slice(1) : line,
        oldNo: oldLineNo++,
        newNo: newLineNo++,
      });
    }
  }

  // 计算文件状态
  for (const f of files) {
    if (f.deletions === 0 && f.additions > 0) {
      f.status = "added";
    } else if (f.additions === 0 && f.deletions > 0) {
      f.status = "deleted";
    } else {
      f.status = "modified";
    }
  }

  return files;
}
