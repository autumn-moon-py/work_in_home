'use strict';

// 薄壳：把「释放占用」挂到资源管理器右键，逻辑全部复用 ./release.js（安装时复制到同目录）。
const vscode = require('vscode');
const { releaseLocks } = require('./release.js');

const ACTION_LABEL = { killed: '已终止', skipped: '跳过', denied: '无权终止', failed: '终止后仍占用' };

let out;

async function releaseCommand(uri) {
  if (process.platform !== 'darwin') {
    vscode.window.showWarningMessage('释放占用仅支持 macOS。');
    return;
  }
  const target = uri && uri.fsPath;
  if (!target) {
    vscode.window.showWarningMessage('请先在资源管理器里选中一个文件或文件夹。');
    return;
  }

  let result;
  try {
    result = await vscode.window.withProgress(
      { location: vscode.ProgressLocation.Notification, title: `释放占用: ${target.split('/').pop()}` },
      () => releaseLocks(target, {}));
  } catch (e) {
    vscode.window.showErrorMessage(`释放占用失败: ${e.message}`);
    return;
  }

  out.appendLine(`--- ${new Date().toISOString()}  ${target}`);
  if (!result.holders.length) out.appendLine('无占用持有者。');
  for (const h of result.holders) {
    out.appendLine(`[${h.category}] pid ${h.pid}  ${ACTION_LABEL[h.action] || h.action}${h.error ? `（${h.error}）` : ''}`);
    out.appendLine(`    ${h.command}`);
  }
  if (result.timedOut) out.appendLine('注意: lsof 采集超时，结果可能不完整。');

  const name = target.split('/').pop();
  if (!result.holders.length) {
    vscode.window.showInformationMessage(`${name}: 无占用`);
  } else if (result.remaining === 0) {
    vscode.window.showInformationMessage(`${name}: 已释放 ${result.released} 个进程，占用已清空`);
  } else if (result.holders.some((h) => h.category === 'C2')) {
    vscode.window.showWarningMessage(`${name}: 占用者含 IDE 核心进程，无法单独终止，需重载窗口`);
  } else {
    vscode.window.showWarningMessage(`${name}: 仍有 ${result.remaining} 个进程占用，详见「Lock Release」输出面板`);
  }
}

function activate(context) {
  out = vscode.window.createOutputChannel('Lock Release');
  context.subscriptions.push(out);
  context.subscriptions.push(vscode.commands.registerCommand('lockRelease.release', releaseCommand));
}

module.exports = { activate };
