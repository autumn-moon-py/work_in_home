#!/usr/bin/env node
'use strict';

// 释放指定文件/文件夹的本地进程占用。
// 背景：macOS 上 SMB 卷里只要子树内有文件被打开，其所有祖先目录都无法重命名（EACCES）。
// 见 AGENTS.md 与 docs/superpowers/specs/2026-10-10-lock-release-design.md。

const { execFile } = require('child_process');
const fs = require('fs');
const path = require('path');

const LSOF = '/usr/sbin/lsof';
const PS = '/bin/ps';

// 不确定 lsof 是否会转义（空格实测不转义，\xNN 见过），统一兜一层
function unescapeLsof(s) {
  return s.replace(/\\(x[0-9a-fA-F]{2}|.)/g, (m, g) =>
    g[0] === 'x' ? String.fromCharCode(parseInt(g.slice(1), 16)) : g);
}

function run(cmd, args, timeoutMs) {
  return new Promise((resolve) => {
    execFile(cmd, args, { encoding: 'utf8', timeout: timeoutMs, maxBuffer: 64 * 1024 * 1024 },
      (err, stdout) => resolve({ stdout: stdout || '', timedOut: !!(err && err.killed), err }));
  });
}

// lsof -F pcfn 是机器可读输出：p=pid c=命令名 f=fd n=路径
function parseLsof(stdout) {
  const entries = [];
  let pid = null, fd = null;
  for (const line of stdout.split('\n')) {
    if (!line) continue;
    const tag = line[0], val = line.slice(1);
    if (tag === 'p') { pid = Number(val); fd = null; }
    else if (tag === 'f') { fd = val; }
    else if (tag === 'n' && pid !== null && fd !== null && /^\d+$/.test(fd)) {
      entries.push({ pid, fd: Number(fd), name: unescapeLsof(val) });
    }
  }
  return entries;
}

async function describePids(pids) {
  const map = new Map();
  if (!pids.length) return map;
  const { stdout } = await run(PS, ['-o', 'pid=,ppid=,command=', '-p', pids.join(',')], 5000);
  for (const line of stdout.split('\n')) {
    const m = line.match(/^\s*(\d+)\s+(\d+)\s+(.*)$/);
    if (m) map.set(Number(m[1]), { ppid: Number(m[2]), command: m[3] });
  }
  return map;
}

const EXT_DIR = /(?:\.trae-cn|\.trae|\.vscode)\/extensions\//;

// C1 可安全终止的 IDE 辅助进程（语言服务），C2 禁止终止的 IDE 核心进程，C3 其他
function classify(pid, command, selfPid) {
  if (pid === 1 || pid === selfPid) return { category: 'C2', reason: '受保护进程' };
  const isElectronCore = /--type=(?:renderer|gpu|utility|zygote)\b/.test(command) ||
    /--vscode-crash-reporter-process-type=/.test(command);
  const isLangService = /--node-ipc\b/.test(command) ||
    /--clientProcessId=/.test(command) ||
    (EXT_DIR.test(command) && /\.js\b/.test(command));
  if (isLangService && !isElectronCore) return { category: 'C1', reason: 'IDE 语言服务' };
  if (isElectronCore) return { category: 'C2', reason: 'IDE 核心进程' };
  if (/(^|\/)win_share\b/.test(command)) return { category: 'C2', reason: 'win_share 自身进程' };
  return { category: 'C3', reason: '外部进程' };
}

// 收集目标路径的打开句柄；目录按子树前缀匹配。lsof 报的是解析后的真实路径，两个都试
function collect(target, timeoutMs) {
  let roots = [target];
  try {
    const real = fs.realpathSync(target);
    if (real !== target) roots.push(real);
  } catch (_) { /* 目标不可解析时只用原路径 */ }
  return run(LSOF, ['-nP', '-F', 'pcfn'], timeoutMs).then(({ stdout, timedOut }) => {
    const byPid = new Map();
    for (const e of parseLsof(stdout)) {
      const hit = roots.some((root) => e.name === root || e.name.startsWith(root.endsWith('/') ? root : root + '/'));
      if (!hit) continue;
      if (!byPid.has(e.pid)) byPid.set(e.pid, { pid: e.pid, names: new Set() });
      byPid.get(e.pid).names.add(e.name);
    }
    return { holders: [...byPid.values()], timedOut };
  });
}

async function releaseLocks(targetPath, options = {}) {
  const opts = {
    dryRun: false,
    includeExternal: false,
    timeoutMs: 5000,
    selfPid: process.pid,
    settleMs: 500,
    ...options,
  };
  const target = path.resolve(targetPath);
  if (!fs.existsSync(target)) {
    const err = new Error(`路径不存在: ${target}`);
    err.code = 'ENOENT';
    throw err;
  }

  const first = await collect(target, opts.timeoutMs);
  const meta = await describePids(first.holders.map((h) => h.pid));

  const holders = first.holders.map((h) => {
    const info = meta.get(h.pid) || { ppid: 0, command: '' };
    const cls = classify(h.pid, info.command, opts.selfPid);
    return { pid: h.pid, command: info.command, names: [...h.names], ...cls };
  });

  const killable = holders.filter((h) =>
    h.category === 'C1' || (h.category === 'C3' && opts.includeExternal));

  const killed = [];
  if (!opts.dryRun) {
    for (const h of killable) {
      try {
        process.kill(h.pid, 'SIGTERM');
        killed.push(h);
      } catch (e) {
        h.action = 'denied';
        h.error = e.message;
      }
    }
    if (killed.length) await new Promise((r) => setTimeout(r, opts.settleMs));
  }

  const after = opts.dryRun ? first : await collect(target, opts.timeoutMs);
  const alivePids = new Set(after.holders.map((h) => h.pid));

  for (const h of holders) {
    if (h.action) continue; // 已标记 denied
    if (opts.dryRun) { h.action = 'skipped'; continue; }
    if (!killable.includes(h)) { h.action = 'skipped'; continue; }
    if (alivePids.has(h.pid)) { h.action = 'failed'; h.error = '发送 SIGTERM 后仍被占用'; }
    else { h.action = 'killed'; }
  }

  const remaining = alivePids.size;
  return {
    path: target,
    holders: holders.map((h) => ({
      pid: h.pid, command: h.command, category: h.category,
      action: h.action, error: h.error || null,
    })),
    released: killed.filter((h) => !alivePids.has(h.pid)).length,
    remaining,
    timedOut: first.timedOut,
    dryRun: opts.dryRun,
  };
}

const USAGE = `用法: lock-release <路径> [--dry-run] [--include-external] [--json] [--timeout 秒]

  默认只终止 IDE 语言服务（可安全重启）；其他进程仅报告，
  加 --include-external 才终止。--dry-run 只列出，不发信号。
  退出码: 0 已无占用 / 1 仍有占用 / 2 用法错误`;

function printHuman(r) {
  console.log(`目标: ${r.path}`);
  if (!r.holders.length) {
    console.log('无占用持有者。');
  } else {
    console.log('持有者:');
    for (const h of r.holders) {
      const label = { killed: '已终止', skipped: '跳过', denied: '无权终止', failed: '终止后仍占用' }[h.action] || h.action;
      console.log(`  [${h.category}] pid ${h.pid}  ${h.command.slice(0, 110)}`);
      console.log(`        -> ${label}${h.error ? `（${h.error}）` : ''}`);
    }
  }
  console.log(`结果: 已释放 ${r.released}，剩余占用 ${r.remaining}${r.dryRun ? '（dry-run，未发信号）' : ''}`);
  if (r.timedOut) console.log('注意: lsof 采集超时，结果可能不完整。');
  if (r.holders.some((h) => h.category === 'C2')) {
    console.log('提示: C2 为 IDE 核心进程，无法单独终止，请在 IDE 里「重载窗口」。');
  }
}

async function main(argv) {
  const args = argv.slice(2);
  const opts = {};
  const paths = [];
  for (let i = 0; i < args.length; i++) {
    const a = args[i];
    if (a === '--dry-run') opts.dryRun = true;
    else if (a === '--include-external') opts.includeExternal = true;
    else if (a === '--json') opts.json = true;
    else if (a === '--timeout') opts.timeoutMs = Number(args[++i]) * 1000;
    else if (a === '-h' || a === '--help') { console.log(USAGE); return 0; }
    else if (a.startsWith('-')) { console.error(`未知参数: ${a}\n${USAGE}`); return 2; }
    else paths.push(a);
  }
  if (paths.length !== 1 || (opts.timeoutMs !== undefined && !(opts.timeoutMs > 0))) {
    console.error(USAGE);
    return 2;
  }
  const result = await releaseLocks(paths[0], opts);
  if (opts.json) console.log(JSON.stringify(result, null, 2));
  else printHuman(result);
  return result.remaining > 0 ? 1 : 0;
}

if (require.main === module) {
  main(process.argv).then((code) => process.exit(code)).catch((e) => {
    console.error(`错误: ${e.message}`);
    process.exit(e.code === 'ENOENT' ? 2 : 1);
  });
}

module.exports = { releaseLocks, classify, parseLsof };
