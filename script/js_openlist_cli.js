'use strict';

const DELETE_POLICIES = new Set([
  'delete_on_upload_succeed',
  'delete_on_upload_failed',
  'delete_never',
  'delete_always',
  'upload_download_stream',
]);

class OpenListError extends Error {
  constructor(message, details = {}) {
    super(message);
    this.name = 'OpenListError';
    Object.assign(this, details);
  }
}

function normalizeCloudPath(input) {
  if (typeof input !== 'string' || !input.startsWith('/')) {
    throw new OpenListError(`cloud path must be absolute: ${input}`);
  }
  if (/[\r\n]/.test(input)) throw new OpenListError('cloud path cannot contain a line break');

  const stack = [];
  for (const part of input.split('/')) {
    if (!part || part === '.') continue;
    if (part === '..') {
      if (!stack.length) throw new OpenListError(`cloud path escapes root: ${input}`);
      stack.pop();
    } else {
      stack.push(part);
    }
  }
  return stack.length ? `/${stack.join('/')}` : '/';
}

function cloudParent(input) {
  const path = normalizeCloudPath(input);
  if (path === '/') throw new OpenListError('root path has no parent');
  const index = path.lastIndexOf('/');
  return index === 0 ? '/' : path.slice(0, index);
}

function cloudBasename(input) {
  const path = normalizeCloudPath(input);
  if (path === '/') throw new OpenListError('root path has no basename');
  return path.slice(path.lastIndexOf('/') + 1);
}

function validateComponent(label, value) {
  if (!value) throw new OpenListError(`${label} cannot be empty`);
  if (value === '.' || value === '..' || /[\\/]/.test(value)) {
    throw new OpenListError(`${label} must be a single file name`);
  }
  if (/[\r\n]/.test(value)) throw new OpenListError(`${label} cannot contain a line break`);
}

function positiveInteger(label, value) {
  const number = Number(value);
  if (!Number.isSafeInteger(number) || number <= 0) {
    throw new OpenListError(`${label} must be a positive integer`);
  }
  return number;
}

function groupPaths(paths) {
  const normalized = [...new Set(paths.map(normalizeCloudPath))];
  if (normalized.includes('/')) throw new OpenListError('cannot operate on root path');
  const groups = new Map();
  for (const path of normalized) {
    const parent = cloudParent(path);
    const names = groups.get(parent) || [];
    names.push(cloudBasename(path));
    groups.set(parent, names);
  }
  return { normalized, groups };
}

function encodeHeaderPath(path) {
  return encodeURIComponent(path).replace(/'/g, '%27').replace(/!/g, '%21');
}

class OpenListClient {
  constructor(options = {}) {
    const baseUrl = options.baseUrl || process.env.OPENLIST_BASE_URL || '';
    const token = options.token || process.env.OPENLIST_TOKEN || '';
    if (!baseUrl || /[\r\n]/.test(baseUrl)) throw new OpenListError('missing or invalid OpenList base URL');
    this.baseUrl = baseUrl.replace(/\/+$/, '');
    this.token = token;
    this.verbose = Boolean(options.verbose);
    this.fetch = options.fetch || globalThis.fetch;
    if (typeof this.fetch !== 'function') throw new OpenListError('global fetch is unavailable');
    try {
      new URL(this.baseUrl);
    } catch {
      throw new OpenListError(`invalid OpenList base URL: ${this.baseUrl}`);
    }
  }

  async request(method, endpoint, body, options = {}) {
    const authenticated = options.authenticated !== false;
    if (authenticated && !this.token) throw new OpenListError('missing OpenList token');
    const headers = { Accept: 'application/json' };
    if (authenticated) headers.Authorization = this.token;
    if (body !== undefined) headers['Content-Type'] = 'application/json';
    if (this.verbose) console.error(`${method} ${endpoint}`);

    let response;
    try {
      response = await this.fetch(`${this.baseUrl}${endpoint}`, {
        method,
        headers,
        body: body === undefined ? undefined : JSON.stringify(body),
      });
    } catch (cause) {
      throw new OpenListError(`request failed: ${method} ${endpoint}`, { cause });
    }

    const text = await response.text();
    let result;
    try {
      result = JSON.parse(text);
    } catch {
      throw new OpenListError(`invalid JSON response from ${endpoint}`, {
        status: response.status,
        response: text,
      });
    }
    if (!response.ok || result.code !== 200) {
      throw new OpenListError(`${endpoint}: ${result.message || response.statusText || 'unknown API error'}`, {
        status: response.status,
        response: result,
      });
    }
    return result;
  }

  tools() {
    return this.request('GET', '/api/public/offline_download_tools', undefined, { authenticated: false });
  }

  addOfflineDownload({ path, urls, tool = 'aria2', deletePolicy = 'delete_never' }) {
    const normalizedPath = normalizeCloudPath(path);
    if (!Array.isArray(urls) || !urls.length || urls.some((url) => !url || /[\r\n]/.test(url))) {
      throw new OpenListError('urls must be a non-empty array of valid URL strings');
    }
    if (!tool) throw new OpenListError('tool cannot be empty');
    if (!DELETE_POLICIES.has(deletePolicy)) throw new OpenListError(`invalid delete policy: ${deletePolicy}`);
    return this.request('POST', '/api/fs/add_offline_download', {
      urls,
      path: normalizedPath,
      tool,
      delete_policy: deletePolicy,
    });
  }

  async listTasks({ phase = 'all', status = 'all' } = {}) {
    const phases = phase === 'all' ? ['download', 'transfer'] : [phase];
    const buckets = status === 'all' ? ['undone', 'done'] : [status];
    if (phases.some((value) => !['download', 'transfer'].includes(value))) throw new OpenListError(`invalid phase: ${phase}`);
    if (buckets.some((value) => !['undone', 'done'].includes(value))) throw new OpenListError(`invalid status: ${status}`);

    const tasks = [];
    const responses = [];
    for (const selectedPhase of phases) {
      const kind = selectedPhase === 'download' ? 'offline_download' : 'offline_download_transfer';
      for (const bucket of buckets) {
        const response = await this.request('GET', `/api/task/${kind}/${bucket}`);
        responses.push(response);
        for (const task of response.data || []) tasks.push({ ...task, phase: selectedPhase, bucket });
      }
    }
    return { tasks, responses };
  }

  async deleteTasks(ids, { phase = 'download', cancel = false } = {}) {
    if (!Array.isArray(ids) || !ids.length) throw new OpenListError('at least one task ID is required');
    const kind = phase === 'download' ? 'offline_download' : phase === 'transfer' ? 'offline_download_transfer' : null;
    if (!kind) throw new OpenListError(`invalid phase: ${phase}`);
    const responses = [];
    if (cancel) {
      for (const id of ids) {
        responses.push(await this.request('POST', `/api/task/${kind}/cancel?tid=${encodeURIComponent(id)}`, {}));
      }
    }
    responses.push(await this.request('POST', `/api/task/${kind}/delete_some`, ids));
    return responses;
  }

  async clearTasks({ phase = 'all', succeededOnly = false } = {}) {
    const phases = phase === 'all' ? ['download', 'transfer'] : [phase];
    if (phases.some((value) => !['download', 'transfer'].includes(value))) throw new OpenListError(`invalid phase: ${phase}`);
    const action = succeededOnly ? 'clear_succeeded' : 'clear_done';
    const responses = [];
    for (const selectedPhase of phases) {
      const kind = selectedPhase === 'download' ? 'offline_download' : 'offline_download_transfer';
      responses.push(await this.request('POST', `/api/task/${kind}/${action}`, {}));
    }
    return responses;
  }

  mkdir(path) {
    const normalized = normalizeCloudPath(path);
    if (normalized === '/') throw new OpenListError('cannot create root directory');
    return this.request('POST', '/api/fs/mkdir', { path: normalized });
  }

  list(path, { page = 1, perPage = 100, refresh = false } = {}) {
    return this.request('POST', '/api/fs/list', {
      path: normalizeCloudPath(path),
      page: positiveInteger('page', page),
      per_page: positiveInteger('perPage', perPage),
      refresh: Boolean(refresh),
    });
  }

  info(path) {
    return this.request('POST', '/api/fs/get', { path: normalizeCloudPath(path), password: '' });
  }

  async search(path, keyword, { page = 1, perPage = 100, scope = 0, all = false } = {}) {
    const scopes = { all: 0, dir: 1, file: 2 };
    const scopeValue = typeof scope === 'string' ? scopes[scope] : scope;
    if (![0, 1, 2].includes(scopeValue)) throw new OpenListError(`invalid search scope: ${scope}`);
    if (!keyword) throw new OpenListError('keyword cannot be empty');
    let currentPage = positiveInteger('page', page);
    const limit = positiveInteger('perPage', perPage);
    const items = [];
    const responses = [];
    const seen = new Set();
    do {
      const response = await this.request('POST', '/api/fs/search', {
        parent: normalizeCloudPath(path), keyword, scope: scopeValue, page: currentPage, per_page: limit,
      });
      responses.push(response);
      const content = response.data?.content || [];
      for (const item of content) {
        const key = `${item.parent || ''}/${item.name || ''}`;
        if (!seen.has(key)) {
          seen.add(key);
          items.push(item);
        }
      }
      if (!all || content.length < limit || items.length >= Number(response.data?.total || 0)) break;
      currentPage += 1;
    } while (true);
    return { items, responses };
  }

  async remove(paths) {
    const { normalized, groups } = groupPaths(paths);
    const responses = [];
    for (const [dir, names] of groups) responses.push(await this.request('POST', '/api/fs/remove', { dir, names }));
    return { paths: normalized, responses };
  }

  async transfer(operation, paths, targetDir, options = {}) {
    if (!['move', 'copy'].includes(operation)) throw new OpenListError(`invalid operation: ${operation}`);
    if (options.overwrite && options.skipExisting) throw new OpenListError('overwrite and skipExisting cannot both be enabled');
    if (operation === 'move' && options.merge) throw new OpenListError('merge is only valid for copy');
    const { normalized, groups } = groupPaths(paths);
    const destination = normalizeCloudPath(targetDir);
    const responses = [];
    for (const [srcDir, names] of groups) {
      responses.push(await this.request('POST', `/api/fs/${operation}`, {
        src_dir: srcDir,
        dst_dir: destination,
        names,
        overwrite: Boolean(options.overwrite),
        skip_existing: Boolean(options.skipExisting),
        merge: Boolean(options.merge),
      }));
    }
    return { paths: normalized, targetDir: destination, responses };
  }

  move(paths, targetDir, options) {
    return this.transfer('move', paths, targetDir, options);
  }

  copy(paths, targetDir, options) {
    return this.transfer('copy', paths, targetDir, options);
  }

  async rename(entries, { overwrite = false } = {}) {
    if (!Array.isArray(entries) || !entries.length) throw new OpenListError('at least one rename entry is required');
    const responses = [];
    for (const entry of entries) {
      const path = normalizeCloudPath(entry.path);
      if (path === '/') throw new OpenListError('cannot rename root path');
      validateComponent('name', entry.name);
      responses.push(await this.request('POST', '/api/fs/rename', {
        path,
        name: entry.name,
        overwrite: Boolean(overwrite),
      }));
    }
    return responses;
  }

  async upload(path, data, { asTask = false, overwrite = true } = {}) {
    const normalized = normalizeCloudPath(path);
    if (normalized === '/') throw new OpenListError('upload path must include a file name');
    if (!this.token) throw new OpenListError('missing OpenList token');
    if (this.verbose) console.error(`PUT /api/fs/put`);
    const response = await this.fetch(`${this.baseUrl}/api/fs/put`, {
      method: 'PUT',
      headers: {
        Accept: 'application/json',
        Authorization: this.token,
        'File-Path': encodeHeaderPath(normalized),
        'As-Task': String(Boolean(asTask)),
        Overwrite: String(Boolean(overwrite)),
      },
      body: data,
    });
    const text = await response.text();
    let result;
    try { result = JSON.parse(text); } catch { throw new OpenListError('invalid JSON response from /api/fs/put'); }
    if (!response.ok || result.code !== 200) throw new OpenListError(`/api/fs/put: ${result.message || response.statusText}`, { response: result });
    return result;
  }

  async getDownload(path) {
    const response = await this.info(path);
    const rawUrl = response.data?.raw_url;
    if (!rawUrl) throw new OpenListError('OpenList did not return a raw_url');
    return { response, url: new URL(rawUrl, `${new URL(this.baseUrl).origin}/`).href };
  }

  async download(path) {
    const details = await this.getDownload(path);
    const response = await this.fetch(details.url, { redirect: 'follow' });
    if (!response.ok) throw new OpenListError(`download failed: HTTP ${response.status}`);
    return { data: new Uint8Array(await response.arrayBuffer()), response: details.response, url: details.url };
  }
}

function usage() {
  return `Usage: node script/js_openlist_cli.js COMMAND [options]\n\nCommands:\n  offline-tools\n  offline-add --dir PATH --url URL [--url URL ...] [--tool NAME]\n  offline-list [--phase download|transfer|all] [--status undone|done|all]\n  offline-delete --id ID [--id ID ...] [--phase download|transfer] [--cancel]\n  offline-clear [--phase download|transfer|all] [--succeeded-only]\n  mkdir --dir PATH\n  ls --dir PATH [--page N] [--limit N] [--refresh]\n  info --path PATH\n  search --dir PATH --keyword TEXT [--scope all|dir|file] [--all]\n  rm --path PATH [--path PATH ...]\n  mv|cp --path PATH [--path PATH ...] --target-dir PATH\n  rename --path PATH --name NAME [--overwrite]\n  upload --path REMOTE_PATH --file LOCAL_FILE [--as-task] [--no-overwrite]\n  download --path REMOTE_PATH --output LOCAL_FILE\n\nCommon options: --base-url URL --token TOKEN --json --raw-response --verbose`;
}

function parseArgs(argv) {
  const values = Object.create(null);
  const flags = new Set();
  const positional = [];
  const repeatable = new Set(['path', 'url', 'id', 'name']);
  const boolean = new Set(['json', 'raw-response', 'verbose', 'refresh', 'all', 'overwrite', 'skip-existing', 'merge', 'cancel', 'succeeded-only', 'as-task', 'no-overwrite', 'help']);
  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    if (!arg.startsWith('--')) { positional.push(arg); continue; }
    const key = arg.slice(2);
    if (boolean.has(key)) { flags.add(key); continue; }
    if (index + 1 >= argv.length) throw new OpenListError(`missing value for ${arg}`);
    const value = argv[++index];
    if (repeatable.has(key)) (values[key] ||= []).push(value);
    else values[key] = value;
  }
  return { values, flags, positional };
}

async function runCli(argv = process.argv.slice(2), env = process.env) {
  const parsed = parseArgs(argv);
  const command = parsed.positional[0];
  if (!command || parsed.flags.has('help')) return { help: usage() };
  const { values: value, flags } = parsed;
  const client = new OpenListClient({
    baseUrl: value['base-url'] || env.OPENLIST_BASE_URL,
    token: value.token || env.OPENLIST_TOKEN,
    verbose: flags.has('verbose'),
  });
  let result;
  switch (command) {
    case 'offline-tools': result = await client.tools(); break;
    case 'mkdir': result = await client.mkdir(value.dir); break;
    case 'ls': result = await client.list(value.dir, { page: value.page || 1, perPage: value.limit || 100, refresh: flags.has('refresh') }); break;
    case 'info': result = await client.info((value.path || [])[0]); break;
    case 'search': result = await client.search(value.dir, value.keyword, { page: value.page || 1, perPage: value.limit || 100, scope: value.scope || 'all', all: flags.has('all') }); break;
    case 'rm': result = await client.remove(value.path || []); break;
    case 'mv': result = await client.move(value.path || [], value['target-dir'], { overwrite: flags.has('overwrite'), skipExisting: flags.has('skip-existing') }); break;
    case 'cp': result = await client.copy(value.path || [], value['target-dir'], { overwrite: flags.has('overwrite'), skipExisting: flags.has('skip-existing'), merge: flags.has('merge') }); break;
    case 'rename': {
      const paths = value.path || [];
      const names = value.name || [];
      if (paths.length !== names.length) throw new OpenListError('rename requires equal numbers of --path and --name values');
      result = await client.rename(paths.map((path, index) => ({ path, name: names[index] })), { overwrite: flags.has('overwrite') });
      break;
    }
    case 'offline-add': result = await client.addOfflineDownload({ path: value.dir, urls: value.url || [], tool: value.tool || 'aria2', deletePolicy: value['delete-policy'] || 'delete_never' }); break;
    case 'offline-list': result = await client.listTasks({ phase: value.phase || 'all', status: value.status || 'all' }); break;
    case 'offline-delete': result = await client.deleteTasks(value.id || [], { phase: value.phase || 'download', cancel: flags.has('cancel') }); break;
    case 'offline-clear': result = await client.clearTasks({ phase: value.phase || 'all', succeededOnly: flags.has('succeeded-only') }); break;
    case 'upload': {
      const fs = require('node:fs');
      if (!value.file) throw new OpenListError('upload requires --file');
      result = await client.upload((value.path || [])[0], fs.readFileSync(value.file), { asTask: flags.has('as-task'), overwrite: !flags.has('no-overwrite') });
      break;
    }
    case 'download': {
      const fs = require('node:fs');
      const remotePath = (value.path || [])[0];
      const output = value.output || cloudBasename(remotePath);
      const downloaded = await client.download(remotePath);
      fs.writeFileSync(output, downloaded.data);
      result = { code: 200, message: 'success', data: { path: remotePath, output, bytes: downloaded.data.byteLength } };
      break;
    }
    default: throw new OpenListError(`unknown command: ${command}`);
  }
  return flags.has('raw-response') ? result : { success: true, command, data: result.data ?? result };
}

if (typeof require !== 'undefined' && require.main === module) {
  runCli().then((result) => {
    if (result.help) console.log(result.help);
    else console.log(JSON.stringify(result));
  }).catch((error) => {
    console.error(`error: ${error.message}`);
    process.exitCode = 1;
  });
}

module.exports = {
  OpenListClient,
  OpenListError,
  normalizeCloudPath,
  cloudParent,
  cloudBasename,
  groupPaths,
  runCli,
};
